import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
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

  /// A pending enrollment whose record holds [stored], an expiry no request
  /// may ask for.
  Future<String> pendingHolding(String name, Duration stored) async {
    final id = await pending(name);
    final key = enMgr.buildEnrollmentKey(id);
    final atData = (await keyValueStore.get(key))!;
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData.data!));
    value.apkamKeysExpiryDuration = stored;
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(id, atData, EnrollmentStatus.pending);
    final reread = EnrollDataStoreValue.fromJson(
        jsonDecode((await keyValueStore.get(key))!.data!));
    expect(reread.apkamKeysExpiryDuration, stored,
        reason: 'precondition: B\'s pending record holds $stored');
    return id;
  }

  /// Runs `enroll:<operation>` on [targetId] over [inboundConnection] as it
  /// stands.
  Future<Response> send(String operation, String targetId) async {
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

  /// Runs `enroll:<operation>` on [targetId] over a connection authenticated
  /// as [callerId], or over a CRAM connection when [callerId] is null.
  Future<Response> decide(String operation, String? callerId, String targetId) {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = callerId == null ? AuthType.cram : AuthType.apkam;
    inboundConnection.metadata.enrollmentId = callerId;
    return send(operation, targetId);
  }

  /// Sends `enroll:request` over a CRAM connection, asking for [asking], and
  /// returns the enrollment it creates, which the connection then carries.
  Future<String> requestOverCram({Duration? asking}) async {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram
      ..sessionID = DateTime.now().microsecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = null;
    final ep = EnrollParams()
      ..appName = 'cram-app'
      ..deviceName = 'cram-device-${DateTime.now().microsecondsSinceEpoch}'
      ..apkamPublicKey = 'apkam public key cram'
      ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key cram'
      ..namespaces = {'*': 'rw'}
      ..apkamKeysExpiryDuration = asking;
    final r = Response();
    await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
    return jsonDecode(r.data!)['enrollmentId'];
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

  /// Approves [b] as [a], returning the response and the moments the
  /// approval began and ended.
  Future<(Response, DateTime, DateTime)> approveTimed(String a, String b) async {
    final DateTime start = DateTime.now().toUtc();
    final Response r = await decide('approve', a, b);
    return (r, start, DateTime.now().toUtc());
  }

  /// B's `apkamKeysExpiryInMillis` as [a] reads it through `enroll:list` and
  /// `enroll:fetch`.
  Future<List<(String, dynamic)>> termAsRead(String a, String b) async {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = a;
    final list = Response();
    await etu.evh.processVerb(
        list, getVerbParam(VerbSyntax.enroll, 'enroll:list'), inboundConnection);
    final fetch = Response();
    await etu.evh.processVerb(
        fetch,
        getVerbParam(VerbSyntax.enroll,
            'enroll:fetch:${jsonEncode({'enrollmentId': b})}'),
        inboundConnection);
    return [
      (
        'enroll:list',
        jsonDecode(list.data!)[enMgr.buildEnrollmentKey(b)]
            ['apkamKeysExpiryInMillis']
      ),
      ('enroll:fetch', jsonDecode(fetch.data!)['apkamKeysExpiryInMillis']),
    ];
  }

  /// Checks B's record, both encryption keys stored on approval, the approve
  /// response, and the term [a] reads for B, against [expected], for an
  /// approval that ran from [start] to [end].
  Future<void> expectApprovedExpiringAt(String a, String b, Response approval,
      DateTime expected, DateTime start, DateTime end) async {
    expect(await statusOf(b), EnrollmentStatus.approved.name);
    expectSameMoment(await recordExpiry(b), expected, 'B\'s record');
    expectSameMoment(
        await expiryOf(enMgr.keyForPEK(b)), expected, 'B\'s encryption key');
    expectSameMoment(await expiryOf(enMgr.keyForSEK(b)), expected,
        'B\'s self encryption key');
    expect(jsonDecode(approval.data!)['expiresAt'],
        EnrollmentManager.expiresAtField(expected));

    // NOTE a millisecond of slack either way: stored instants are truncated.
    final int earliest = expected.difference(end).inMilliseconds - 1;
    final int latest = expected.difference(start).inMilliseconds + 1;
    for (final (String verb, dynamic term) in await termAsRead(a, b)) {
      expect(term, isA<int>(), reason: verb);
      expect(term >= 1 && term >= earliest && term <= latest, isTrue,
          reason: '$verb shows B\'s apkamKeysExpiryInMillis as $term, not '
              'the time from its approval to $expected ($earliest..$latest)');
    }
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
      ('an expiry later than T', [Duration(hours: 2)]),
    ]) {
      test(example, () async {
        for (final (int i, Duration? requested) in requests.indexed) {
          final b = await pending('b$i', expiry: requested);
          final (r, start, end) = await approveTimed(a, b);
          await expectApprovedExpiringAt(a, b, r, t, start, end);
        }
      });
    }

    test('an expiry earlier than T', () async {
      final b = await pending('b', expiry: Duration(minutes: 10));
      final (r, start, after) = await approveTimed(a, b);
      // NOTE floored to the millisecond, the precision an expiry is stored at.
      final before = DateTime.fromMillisecondsSinceEpoch(
          start.millisecondsSinceEpoch,
          isUtc: true);

      final DateTime granted = (await recordExpiry(b))!;
      expect(granted.isBefore(t), isTrue,
          reason: 'the earlier expiry B asked for is kept');
      expect(
          !granted.isBefore(before.add(Duration(minutes: 10))) &&
              !granted.isAfter(after.add(Duration(minutes: 10))),
          isTrue,
          reason: 'B expires ten minutes after its approval, between '
              '$before and $after plus ten minutes, but at $granted');
      await expectApprovedExpiringAt(a, b, r, granted, start, after);
    });
  });

  group(
      'A pending record holding an expiry outside the request bound is '
      'capped at the approver\'s', () {
    late String a;
    late DateTime t;

    setUp(() async {
      a = await approver('a', expiry: Duration(hours: 1));
      t = (await recordExpiry(a))!;
    });

    for (final (String example, Duration stored) in [
      ('a negative expiry', Duration(milliseconds: -1)),
      (
        'an expiry too long for a deadline to be computed from it',
        Duration(milliseconds: 9000000000000000)
      ),
    ]) {
      test(example, () async {
        final b = await pendingHolding('b', stored);
        final (r, start, end) = await approveTimed(a, b);
        await expectApprovedExpiringAt(a, b, r, t, start, end);
      });
    }
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

    final b2 = await pending('b2');
    final String root = await requestOverCram(asking: Duration(hours: 1));
    expect(inboundConnection.metadata.enrollmentId, root,
        reason: 'precondition: a CRAM connection that has run enroll:request '
            'carries the enrollment it created');

    await send('approve', b2);

    expect(await statusOf(b2), EnrollmentStatus.approved.name);
    expect(await recordExpiry(b2), isNull,
        reason: 'an approval over that connection caps nothing either');
  });

  test('An enrollment a CRAM connection requests never expires, and says so',
      () async {
    final String root = await requestOverCram(asking: Duration(hours: 1));

    expect(await statusOf(root), EnrollmentStatus.approved.name);
    expect(await recordExpiry(root), isNull);

    final list = Response();
    await etu.evh.processVerb(list,
        getVerbParam(VerbSyntax.enroll, 'enroll:list'), inboundConnection);
    expect(
        jsonDecode(list.data!)[enMgr.buildEnrollmentKey(root)]
            ['apkamKeysExpiryInMillis'],
        0,
        reason: 'enroll:list');
    final fetch = Response();
    await etu.evh.processVerb(
        fetch,
        getVerbParam(VerbSyntax.enroll,
            'enroll:fetch:${jsonEncode({'enrollmentId': root})}'),
        inboundConnection);
    expect(jsonDecode(fetch.data!)['apkamKeysExpiryInMillis'], 0,
        reason: 'enroll:fetch');
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

  test('An approver whose expiry has passed cannot approve', () async {
    final a = await approver('a', expiry: Duration(seconds: 2));
    final DateTime t = (await recordExpiry(a))!;
    final c = await pending('c');
    final b = await pending('b');
    await decide('approve', a, c);
    expect(await statusOf(c), EnrollmentStatus.approved.name,
        reason: 'control: A approves before its expiry');

    await Future.delayed(
        t.difference(DateTime.now().toUtc()) + Duration(milliseconds: 50));
    await expectLater(
        decide('approve', a, b),
        throwsA(isA<UnAuthorizedException>().having((e) => e.message,
            'message', contains('not authorized for namespaces'))));

    expect(await statusOf(b), EnrollmentStatus.pending.name);
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

  test('An enrollment moved onto a successor keeps its own expiry', () async {
    final p = await approver('p', expiry: Duration(hours: 1));
    final DateTime t = (await recordExpiry(p))!;
    final c = await pending('c');
    await decide('approve', p, c);
    expectSameMoment(await recordExpiry(c), t, 'precondition: C\'s record');

    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().microsecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = p;
    final ep = EnrollParams()
      ..appName = 'p-successor'
      ..deviceName = 'device-p-successor'
      ..apkamPublicKey = 'apkam public key p-successor'
      ..apkamKeysExpiryDuration = Duration(minutes: 10);
    final sr = Response();
    await etu.evh.processVerb(
        sr,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
        inboundConnection);
    expect(sr.isError, false, reason: '${sr.errorMessage}');
    final String s = jsonDecode(sr.data!)['enrollmentId'];
    final DateTime t2 = (await recordExpiry(s))!;
    expect(t2.isBefore(t), isTrue,
        reason: 'precondition: S ends at $t2, before T');

    await enMgr.settlePredecessorOnFirstAuth(s);

    expect(await enMgr.descendantsOf(s), contains(c),
        reason: 'precondition: C moved onto S');
    expectSameMoment(await recordExpiry(c), t, 'C\'s record');
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
