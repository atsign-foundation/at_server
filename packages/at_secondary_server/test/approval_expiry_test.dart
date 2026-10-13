import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Catalogue: features/enrollment/approval_expiry.feature
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  const approverGrants = {'__manage': 'rw', 'test': 'r'};

  Future<String> pending(String name,
          {Map<String, String> namespaces = const {'test': 'r'},
          Duration? expiry,
          String? apkamPublicKey,
          String? signingAlgo}) =>
      etu.createPendingEnrollment(
          appName: name,
          deviceName: 'device-$name',
          namespaces: namespaces,
          apkamKeysExpiryDuration: expiry,
          apkamPublicKey: apkamPublicKey,
          signingAlgo: signingAlgo);

  /// An approved enrollment holding `__manage`, admitted by the primary
  /// enrollment.
  Future<String> approver(String name, {Duration? expiry}) async {
    final id =
        await pending(name, namespaces: approverGrants, expiry: expiry);
    await etu.approveEnrollment(etu.primaryEnId, id);
    return id;
  }

  /// Runs `enroll:<operation>` on [targetId] over a connection authenticated
  /// as [callerId], or over a CRAM connection when [callerId] is null.
  Future<Response> decide(
      String operation, String? callerId, String targetId) async {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = callerId == null ? AuthType.cram : AuthType.apkam;
    inboundConnection.metadata.enrollmentId = callerId;
    final p = EnrollParams()..enrollmentId = targetId;
    if (operation == 'approve') {
      p
        ..encryptedDefaultEncryptionPrivateKey =
            'encrypted default encryption private key'
        ..encryptedDefaultSelfEncryptionKey =
            'encrypted default self encryption key';
    }
    final r = Response();
    await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:$operation:${jsonEncode(p.toJson())}'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
    return r;
  }

  Future<DateTime?> expiryOf(String key) async =>
      (await keyValueStore.getMeta(key))?.expiresAt?.toUtc();

  Future<DateTime?> recordExpiry(String id) =>
      expiryOf(enMgr.buildEnrollmentKey(id));

  Future<String?> statusOf(String id) async =>
      (await enMgr.getEnrollmentById(id)).approval?.state;

  void expectSameMoment(DateTime? actual, DateTime expected, String what) {
    expect(actual, isNotNull, reason: '$what has no expiry');
    expect(actual!.isAtSameMomentAs(expected), isTrue,
        reason: '$what expires at $actual, not $expected');
  }

  /// Checks B's record, both encryption keys stored on approval, and the
  /// approve response against [expected].
  Future<void> expectApprovedExpiringAt(
      String b, Response approval, DateTime expected) async {
    expect(await statusOf(b), EnrollmentStatus.approved.name);
    expectSameMoment(await recordExpiry(b), expected, 'B\'s record');
    expectSameMoment(
        await expiryOf(enMgr.keyForPEK(b)), expected, 'B\'s encryption key');
    expectSameMoment(await expiryOf(enMgr.keyForSEK(b)), expected,
        'B\'s self encryption key');
    expect(jsonDecode(approval.data!)['expiresAt'],
        EnrollmentManager.expiresAtField(expected));
  }

  group('An approval caps the approved enrollment\'s expiry at the approver\'s',
      () {
    late String a;
    late DateTime t;

    setUp(() async {
      a = await approver('a', expiry: Duration(hours: 1));
      t = (await recordExpiry(a))!;
    });

    for (final (String example, List<Duration?> requests) in [
      ('no expiry', [null]),
      ('an apkamKeysExpiryInMillis of 0', [Duration.zero]),
      ('a negative expiry', [Duration(milliseconds: -1)]),
      (
        'an expiry later than T',
        // The second is longer than a DateTime can hold.
        [Duration(hours: 2), Duration(milliseconds: 9000000000000000)]
      ),
    ]) {
      test(example, () async {
        for (final (int i, Duration? requested) in requests.indexed) {
          final b = await pending('b$i', expiry: requested);
          final r = await decide('approve', a, b);
          await expectApprovedExpiringAt(b, r, t);
        }
      });
    }

    test('an expiry earlier than T', () async {
      final b = await pending('b', expiry: Duration(minutes: 10));
      // NOTE floored to the millisecond, the precision an expiry is stored at.
      final before = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
          isUtc: true);
      final r = await decide('approve', a, b);
      final after = DateTime.now().toUtc();

      final DateTime granted = (await recordExpiry(b))!;
      expect(granted.isBefore(t), isTrue,
          reason: 'the earlier expiry B asked for is kept');
      expect(
          !granted.isBefore(before.add(Duration(minutes: 10))) &&
              !granted.isAfter(after.add(Duration(minutes: 10))),
          isTrue,
          reason: 'B expires ten minutes after its approval, between '
              '$before and $after plus ten minutes, but at $granted');
      await expectApprovedExpiringAt(b, r, granted);
    });
  });

  test('An approver whose record holds a deadline caps at that deadline',
      () async {
    final predecessor = await approver('p', expiry: Duration(hours: 1));
    final DateTime t = (await recordExpiry(predecessor))!;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = predecessor;
    final ep = EnrollParams()
      ..appName = 'a-successor'
      ..deviceName = 'device-a-successor'
      ..apkamPublicKey = 'apkam public key a-successor';
    final sr = Response();
    await etu.evh.processVerb(
        sr,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
        inboundConnection);
    expect(sr.isError, false, reason: '${sr.errorMessage}');
    final String a = jsonDecode(sr.data!)['enrollmentId'];
    expectSameMoment(await recordExpiry(a), t,
        'precondition: A, which replaced an enrollment expiring at T,');

    // NOTE the pause makes a cap re-derived from A's term land after T.
    await Future.delayed(Duration(milliseconds: 50));
    final b = await pending('b');
    await decide('approve', a, b);

    expectSameMoment(await recordExpiry(b), t, 'B\'s record');
  });

  test('An approver that never expires caps nothing', () async {
    final a = await approver('a');
    final b = await pending('b');

    final r = await decide('approve', a, b);

    expect(await recordExpiry(b), isNull);
    final Map response = jsonDecode(r.data!);
    expect(response.containsKey('expiresAt'), isTrue,
        reason: 'the approve response carries expiresAt');
    expect(response['expiresAt'], isNull);
  });

  test('An approval over a CRAM connection caps nothing', () async {
    final b = await pending('b');

    await decide('approve', null, b);

    expect(await statusOf(b), EnrollmentStatus.approved.name);
    expect(await recordExpiry(b), isNull);
  });

  test('An enrollment capped at its approver\'s expiry ends with it', () async {
    final a = await approver('a', expiry: Duration(seconds: 2));
    final DateTime t = (await recordExpiry(a))!;
    final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
    final b = await pending('b',
        apkamPublicKey: base64Encode(mlDsa.publicKey), signingAlgo: 'mldsa65');
    await decide('approve', a, b);

    var session = 0;
    Future<Response> pkamAsB() async {
      final sessionId = 'cap-session-${session++}';
      const challenge = 'a-per-connection-challenge';
      await keyValueStore.put(
          'private:$sessionId$alice', AtData()..data = challenge);
      final signature = await MlDsa65PureDartAlgo().signBytes(
          Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
          secretKey: mlDsa.secretKey);
      inboundConnection.metaData
        ..isAuthenticated = false
        ..sessionID = sessionId;
      final r = Response();
      await PkamVerbHandler(keyValueStore).processVerb(
          r,
          getVerbParam(
              VerbSyntax.pkam,
              'pkam:signingAlgo:mldsa65:enrollmentId:$b:'
              '${base64Encode(signature)}'),
          inboundConnection);
      return r;
    }

    final before = await pkamAsB();
    expect(before.data, 'success',
        reason: 'control: B authenticates before T, ${before.errorMessage}');

    await Future.delayed(
        t.difference(DateTime.now().toUtc()) + Duration(milliseconds: 300));
    final after = await pkamAsB();

    expect(after.isError, isTrue, reason: 'B\'s pkam is refused once T passes');
    expect(after.errorCode, 'AT0028');
  });

  test('A capped enrollment keeps its expiry through revoke and unrevoke',
      () async {
    final a = await approver('a', expiry: Duration(hours: 1));
    final DateTime t = (await recordExpiry(a))!;
    final b = await pending('b');
    await decide('approve', a, b);
    expectSameMoment(await recordExpiry(b), t, 'precondition: B\'s record');

    await decide('revoke', a, b);
    expect(await statusOf(b), EnrollmentStatus.revoked.name);
    await decide('unrevoke', a, b);
    expect(await statusOf(b), EnrollmentStatus.approved.name);

    expectSameMoment(await recordExpiry(b), t, 'B\'s record');
  });

  group('An approver sees the expiry a pending request asks for', () {
    Future<dynamic> throughList(String a, String b) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.apkam;
      inboundConnection.metadata.enrollmentId = a;
      final r = Response();
      await etu.evh.processVerb(
          r, getVerbParam(VerbSyntax.enroll, 'enroll:list'), inboundConnection);
      expect(r.isError, false, reason: '${r.errorMessage}');
      return jsonDecode(r.data!)[enMgr.buildEnrollmentKey(b)]
          ['apkamKeysExpiryInMillis'];
    }

    Future<dynamic> throughFetch(String a, String b) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.apkam;
      inboundConnection.metadata.enrollmentId = a;
      final r = Response();
      await etu.evh.processVerb(
          r,
          getVerbParam(VerbSyntax.enroll,
              'enroll:fetch:${jsonEncode({'enrollmentId': b})}'),
          inboundConnection);
      expect(r.isError, false, reason: '${r.errorMessage}');
      return jsonDecode(r.data!)['apkamKeysExpiryInMillis'];
    }

    Future<dynamic> throughNotification(String a, String b) async {
      final String key = '$b.new.enrollments.__manage$alice';
      for (final id in await (await notifStore.getKeys()).toList()) {
        final n = await notifStore.get(id);
        if (n != null && n.notification == key) {
          return jsonDecode(n.atValue!)['apkamKeysExpiryInMillis'];
        }
      }
      fail('no notification announces $key');
    }

    for (final (String requested, Duration? expiry, int value) in [
      ('an expiry of 1 hour', Duration(hours: 1), 3600000),
      ('no expiry', null, 0),
    ]) {
      for (final (String read, Future<dynamic> Function(String, String) via)
          in [
        ('enroll:list', throughList),
        ('enroll:fetch', throughFetch),
        ('the new.enrollments.__manage notification', throughNotification),
      ]) {
        test('$requested, through $read', () async {
          final a = await approver('a');
          final b = await pending('b', expiry: expiry);

          expect(await via(a, b), value);
        });
      }
    }
  });
}
