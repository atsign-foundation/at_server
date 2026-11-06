import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_revocation_event.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Scenarios: features/enrollment/namespace_key_holder_revocation.feature
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();
  late String reader;

  final String advertisement = 'public:__nskey.app$alice';
  const Map<String, dynamic> aKeyPackage = {'kid': 'kp-1', 'pub': 'AAAA'};

  void connectAs(String enrollmentId, {AuthType authType = AuthType.apkam}) {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = authType;
    inboundConnection.metadata.enrollmentId = enrollmentId;
  }

  /// An approved enrollment named [name] holding [namespaces], approved by
  /// [approver] or by the atSign's root.
  Future<String> enrolled(String name, Map<String, String> namespaces,
      {Map<String, dynamic>? metadata, String? approver}) async {
    connectAs(etu.primaryEnId);
    final String id = await etu.createPendingEnrollment(
        appName: name,
        deviceName: 'device',
        namespaces: namespaces,
        apkamKeysExpiryDuration: null,
        metadata: metadata);
    await etu.approveEnrollment(approver ?? etu.primaryEnId, id);
    return id;
  }

  Future<Map<String, dynamic>> infons(String namespace) async {
    connectAs(reader);
    final r = Response();
    await etu.evh.processVerb(
        r,
        HashMap<String, String?>.from(
            {'operation': 'infons', 'listNamespace': namespace}),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
    return jsonDecode(r.data!) as Map<String, dynamic>;
  }

  Future<String?> lastKeyHolderRevokedAt() async =>
      (await infons('app'))['lastKeyHolderRevokedAt'] as String?;

  Future<String?> lastRevokedAt() async =>
      (await infons('app'))['lastRevokedAt'] as String?;

  /// The moment the history says [id] was revoked or superseded, read off the
  /// stored event rather than through the derivation under test.
  Future<String> revocationOf(String id) async {
    final es = (await enMgr.revocationEvents())
        .where((e) =>
            e.enrollmentId == id &&
            e.type != EnrollmentRevocationEventType.unrevoked)
        .toList();
    expect(es, hasLength(1),
        reason: 'meaningful only for an enrollment revoked exactly once');
    return es.single.at.toIso8601String();
  }

  Future<void> revoke(String id) => etu.revokeEnrollment(etu.primaryEnId, id);

  Future<void> selfUpdate(String id, Map<String, dynamic> metadata) async {
    connectAs(id);
    final ep = EnrollParams()
      ..enrollmentId = id
      ..metadata = metadata;
    final r = Response();
    await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:update:${jsonEncode(ep.toJson())}'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
  }

  /// Writes [advertisement] over the connection as it stands.
  Future<void> writeAdvertisement(String value) async {
    final r = Response();
    await etu.uvh.processVerb(
        r,
        getVerbParam(VerbSyntax.update, 'update:$advertisement $value'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
  }

  Future<void> writeAdvertisementAsJson(String value) async {
    final json = jsonEncode({
      'atKey': '__nskey.app',
      'value': value,
      'sharedBy': '$alice',
      'metadata': (Metadata()..isPublic = true).toJson(),
    });
    final r = Response();
    await etu.uvh.processVerb(
        r,
        getVerbParam(VerbSyntax.update, 'update:json:$json'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
  }

  Future<void> writeAdvertisementInBatch(String value) async {
    final batch = BatchVerbHandler(
        keyValueStore,
        DefaultVerbHandlerManager(
            keyValueStore,
            mockOutboundClientManager,
            cacheManager,
            statsNotificationService,
            notificationManager,
            enMgr,
            alice,
            commitLog: atCommitLog,
            accessLog: atAccessLog));
    final response = await batch.processInternal(
        'batch:${jsonEncode([
              {'id': 1, 'command': 'update:$advertisement $value'}
            ])}',
        inboundConnection);
    final Map entry = (jsonDecode(response.data!) as List).single as Map;
    expect(entry['response']['error_code'], isNull, reason: '$entry');
  }

  /// A retrofit of [predecessorId] whose successor holds a real ML-DSA
  /// keypair, so it can then authenticate through the production PKAM
  /// handler.
  Future<(String, dynamic)> retrofit(String predecessorId) async {
    final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
    final ep = EnrollParams()
      ..appName = 'rf-app'
      ..deviceName = 'rf-device'
      ..apkamPublicKey = base64Encode(mlDsa.publicKey)
      ..signingAlgo = 'mldsa65';
    connectAs(predecessorId);
    inboundConnection.metaData.sessionID = 'retrofit-session';
    final r = Response();
    await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
    return (jsonDecode(r.data!)['enrollmentId'] as String, mlDsa);
  }

  /// Authenticates as [enrollmentId] through the production PKAM handler.
  Future<void> authenticateAs(String enrollmentId, dynamic mlDsa) async {
    const sessionId = 'first-auth-session';
    const challenge = 'a-per-connection-challenge';
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final signature = await MlDsa65PureDartAlgo().signBytes(
        Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
        secretKey: mlDsa.secretKey);
    inboundConnection.metaData
      ..isAuthenticated = false
      ..sessionID = sessionId;
    final pr = Response();
    await PkamVerbHandler(keyValueStore).processVerb(
        pr,
        getVerbParam(
            VerbSyntax.pkam,
            'pkam:signingAlgo:mldsa65:enrollmentId:$enrollmentId:'
            '${base64Encode(signature)}'),
        inboundConnection);
    expect(pr.data, 'success', reason: '${pr.errorMessage}');
  }

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
    reader = await enrolled('reader', {'app': 'r'});
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group(
      'A revoked enrollment whose record has carried a key package moves '
      'lastKeyHolderRevokedAt', () {
    test('from its enroll:request', () async {
      final e3 = await enrolled('e3', {'app': 'rw'},
          metadata: {'keyPackage': aKeyPackage});

      await revoke(e3);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e3));
    });

    test('from its own enroll:update', () async {
      final e3 = await enrolled('e3', {'app': 'rw'});
      await selfUpdate(e3, {'keyPackage': aKeyPackage});

      await revoke(e3);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e3));
    });
  });

  group(
      'Every kind of revocation of an enrollment that may have held a '
      'namespace key moves it', () {
    test(
        'E3, whose record carried a key package, revoked by the cascade from '
        'revoking the one that approved it', () async {
      final approver =
          await enrolled('approver', {'app': 'rw', '__manage': 'rw'});
      final e3 = await enrolled('e3', {'app': 'rw'},
          metadata: {'keyPackage': aKeyPackage}, approver: approver);

      await revoke(approver);

      expect(
          (await enMgr.revocationEvents())
              .singleWhere((e) => e.enrollmentId == e3)
              .cascadedFrom,
          approver,
          reason: 'precondition: E3 went by the cascade');
      expect(await lastKeyHolderRevokedAt(), await revocationOf(e3));
    });

    test(
        'E2, over whose connection a namespace-key advertisement was written, '
        "superseded by its retrofit's first authentication", () async {
      final e2 = await enrolled('e2', {'app': 'rw'});
      connectAs(e2);
      await writeAdvertisement('nskey-generation-1');
      final (successor, key) = await retrofit(e2);

      await authenticateAs(successor, key);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e2));
    });
  });

  test(
      'An enrollment that updated its key package away before revocation '
      'still moves it', () async {
    final e3 = await enrolled('e3', {'app': 'rw'},
        metadata: {'keyPackage': aKeyPackage});
    await selfUpdate(e3, {'keyPackage': null});
    expect((await enMgr.getEnrollmentById(e3)).metadata!['keyPackage'], isNull,
        reason: 'precondition: the record no longer carries a key package');

    await revoke(e3);

    expect(await lastKeyHolderRevokedAt(), await revocationOf(e3));
  });

  group(
      'A record that carried a key package before the mark existed counts '
      'as marked', () {
    for (final Map<String, dynamic> metadata in [
      {'keyPackage': aKeyPackage},
      {'keyPackage': null},
    ]) {
      test(jsonEncode(metadata), () async {
        final e3 = await enrolled('e3', {'app': 'rw'});
        final Map<String, dynamic> stored = jsonDecode(
            (await keyValueStore.get(enMgr.buildEnrollmentKey(e3)))!.data!);
        stored
          ..remove('keyHolder')
          ..['metadata'] = metadata;
        await enMgr.put(
            e3, AtData()..data = jsonEncode(stored), EnrollmentStatus.approved);

        await revoke(e3);

        expect(await lastKeyHolderRevokedAt(), await revocationOf(e3));
      });
    }
  });

  group(
      'A connection that writes a namespace-key advertisement marks its own '
      'enrollment', () {
    test('E4, over an APKAM connection, a first mint with update:', () async {
      final e4 = await enrolled('e4', {'app': 'rw'});
      connectAs(e4);
      await writeAdvertisement('nskey-generation-1');

      await revoke(e4);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e4));
    });

    test('primary, over a legacy pkam: connection, a first mint with update:',
        () async {
      await enMgr
          .serialiseMutation(() => enMgr.mintPrimary('legacy pkam public key'));
      connectAs(EnrollmentManager.primaryEnrollmentId,
          authType: AuthType.pkamLegacy);
      await writeAdvertisement('nskey-generation-1');

      await revoke(EnrollmentManager.primaryEnrollmentId);

      expect(await lastKeyHolderRevokedAt(),
          await revocationOf(EnrollmentManager.primaryEnrollmentId));
    });

    test(
        'E4, over an APKAM connection, over a key another enrollment '
        'published, with update:', () async {
      final e6 = await enrolled('e6', {'app': 'rw'});
      final e4 = await enrolled('e4', {'app': 'rw'});
      connectAs(e6);
      await writeAdvertisement('nskey-generation-1');
      connectAs(e4);
      await writeAdvertisement('nskey-generation-2');

      await revoke(e4);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e4));
    });

    test('E4, over an APKAM connection, a first mint with update:json',
        () async {
      final e4 = await enrolled('e4', {'app': 'rw'});
      connectAs(e4);
      await writeAdvertisementAsJson('nskey-generation-1');
      expect(
          (await keyValueStore.get(advertisement))?.data, 'nskey-generation-1',
          reason: 'precondition: update:json stored the advertisement');

      await revoke(e4);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e4));
    });

    test('E4, over an APKAM connection, a first mint in a batch: entry',
        () async {
      final e4 = await enrolled('e4', {'app': 'rw'});
      connectAs(e4);
      await writeAdvertisementInBatch('nskey-generation-1');
      expect(
          (await keyValueStore.get(advertisement))?.data, 'nskey-generation-1',
          reason: 'precondition: the batch entry stored the advertisement');

      await revoke(e4);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e4));
    });
  });

  test(
      "Writing a namespace-key advertisement marks only the writing "
      "connection's own enrollment", () async {
    final e4 = await enrolled('e4', {'app': 'rw'});
    final e5 = await enrolled('e5', {'app': 'rw'});
    connectAs(e4);
    await writeAdvertisement('nskey-generation-1');

    await revoke(e5);

    expect(await lastKeyHolderRevokedAt(), isNull);
    expect(await lastRevokedAt(), await revocationOf(e5));

    // Control: the write did mark an enrollment, the one that sent it.
    await revoke(e4);
    expect(await lastKeyHolderRevokedAt(), await revocationOf(e4));
  });

  group(
      'The mark is per enrollment, so a revocation counts for every namespace '
      'its grants reach', () {
    setUp(() async {
      reader = await enrolled('otherreader', {'other': 'r'});
    });

    test(
        'E4, after a connection authenticated as E4 wrote '
        'public:__nskey.app@alice', () async {
      final e4 = await enrolled('e4', {'app': 'rw', 'other': 'rw'});
      connectAs(e4);
      await writeAdvertisement('nskey-generation-1');

      await revoke(e4);

      final Map<String, dynamic> other = await infons('other');
      expect(other['lastKeyHolderRevokedAt'], await revocationOf(e4));
      expect(other['lastRevokedAt'], await revocationOf(e4));
    });

    test('E5, over whose connection nothing was advertised', () async {
      final e5 = await enrolled('e5', {'app': 'rw', 'other': 'rw'});

      await revoke(e5);

      final Map<String, dynamic> other = await infons('other');
      expect(other['lastKeyHolderRevokedAt'], isNull);
      expect(other['lastRevokedAt'], await revocationOf(e5));
    });
  });

  test(
      'A revoke that lands before an advertisement write is stored refuses '
      'the write', () async {
    final e4 = await enrolled('e4', {'app': 'rw'});
    final _ReportsArrival manager = _ReportsArrival(keyValueStore, alice);
    AtSecondaryServerImpl.getInstance().enrollmentManager = manager;

    // Holds the enrollment-mutation section until the write, authorised
    // while E4 was approved, waits on it, then revokes E4 inside it.
    final Future<void> revoking = manager.serialiseMutation(() async {
      await manager.arrived.future;
      await manager.revokeAll([e4],
          byEnrollmentId: etu.primaryEnId,
          cascadedFrom: null,
          at: DateTime.now().toUtc());
    });
    connectAs(e4);
    final Future<void> writing = writeAdvertisement('nskey-generation-1');

    await revoking;
    await expectLater(
        writing,
        throwsA(isA<UnAuthorizedException>().having((e) => e.message, 'message',
            contains('is revoked, not approved'))));
    AtSecondaryServerImpl.getInstance().enrollmentManager = enMgr;

    expect(await keyValueStore.exists(advertisement), false);
    expect(await lastKeyHolderRevokedAt(), isNull);
    expect(await lastRevokedAt(), await revocationOf(e4),
        reason: 'control: E4 was revoked, and the revocation is counted '
            'where every revocation is');
  });

  test('A legacy enrollment superseded by its own retrofit does not move it',
      () async {
    final e2 = await enrolled('e2', {'app': 'rw'});
    final (successor, key) = await retrofit(e2);

    await authenticateAs(successor, key);

    expect(await lastKeyHolderRevokedAt(), isNull);
    expect(await lastRevokedAt(), await revocationOf(e2));
  });

  test(
      'A revocation event recorded before the mark existed counts, '
      'conservatively', () async {
    const String at = '2026-08-31T12:34:56.789Z';
    await keyValueStore.put(
        enMgr.buildRevocationEventKey('recorded-before-the-mark'),
        AtData()
          ..data = jsonEncode({
            'event': 'revoked',
            'enrollmentId': 'an-enrollment-since-removed',
            'at': at,
            'namespaces': {'app': 'rw'},
          }),
        skipCommit: true);

    final info = await infons('app');

    expect(info['lastKeyHolderRevokedAt'], at);
    expect(info['lastRevokedAt'], at);
  });

  group(
      "Whether a revocation moves it rests on the record's mark, never on a "
      'claim', () {
    test('the enroll:revoke request carries "keyHolder": false', () async {
      final e3 = await enrolled('e3', {'app': 'rw'},
          metadata: {'keyPackage': aKeyPackage});
      connectAs(etu.primaryEnId);
      final r = Response();
      await etu.evh.processVerb(
          r,
          getVerbParam(VerbSyntax.enroll,
              'enroll:revoke:{"enrollmentId":"$e3","keyHolder":false}'),
          inboundConnection);
      expect(jsonDecode(r.data!)['status'], EnrollmentStatus.revoked.name,
          reason: '${r.errorMessage}');

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e3));
    });

    test('E3\'s own enroll:update set its metadata to {"keyHolder": false}',
        () async {
      final e3 = await enrolled('e3', {'app': 'rw'},
          metadata: {'keyPackage': aKeyPackage});
      await selfUpdate(e3, {'keyHolder': false});

      await revoke(e3);

      expect(await lastKeyHolderRevokedAt(), await revocationOf(e3));
    });
  });

  group(
      'Un-revoking the last revoked key holder takes lastKeyHolderRevokedAt '
      'back to null', () {
    test('E3, whose record carried a key package', () async {
      final e3 = await enrolled('e3', {'app': 'rw'},
          metadata: {'keyPackage': aKeyPackage});
      await revoke(e3);
      expect(await lastKeyHolderRevokedAt(), await revocationOf(e3),
          reason: 'precondition');

      await etu.unrevokeEnrollment(etu.primaryEnId, e3);

      expect(await lastKeyHolderRevokedAt(), isNull);
    });

    test(
        'E2, whose record has never carried a key package, revoked before '
        'the mark existed', () async {
      final e2 = await enrolled('e2', {'app': 'rw'});
      await revoke(e2);
      final String eventKey = (await (await keyValueStore.getKeys(
                  regex: EnrollmentManager.revocationEventsRegex))
              .toList())
          .single;
      final Map<String, dynamic> stored =
          jsonDecode((await keyValueStore.get(eventKey))!.data!);
      stored.remove('keyHolder');
      await keyValueStore.put(eventKey, AtData()..data = jsonEncode(stored),
          skipCommit: true);
      expect(await lastKeyHolderRevokedAt(), await revocationOf(e2),
          reason: 'precondition: a revocation recorded with no mark counts');

      await etu.unrevokeEnrollment(etu.primaryEnId, e2);

      expect(await lastKeyHolderRevokedAt(), isNull);
    });
  });

  test(
      'enroll:infons answers lastKeyHolderRevokedAt even when nothing '
      'qualifies', () async {
    final e2 = await enrolled('e2', {'app': 'rw'});
    await revoke(e2);

    final info = await infons('app');

    expect(info.containsKey('lastKeyHolderRevokedAt'), isTrue);
    expect(info['lastKeyHolderRevokedAt'], isNull);
    expect(info['lastRevokedAt'], await revocationOf(e2));
  });

  /// Stores [namespace]'s advertisement as a record written before the mark
  /// existed: in the keystore, with no connection to mark.
  Future<void> advertisedBeforeTheMark(String namespace) => keyValueStore.put(
      'public:__nskey.$namespace$alice', AtData()..data = 'nskey-generation-0');

  Future<void> atServerStarts() =>
      AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();

  test(
      'An enrollment that wrote an advertisement before the mark existed, '
      'with no key package, is not marked', () async {
    final e4 = await enrolled('e4', {'app': 'rw'});
    await advertisedBeforeTheMark('app');

    await atServerStarts();
    await revoke(e4);

    expect(await lastKeyHolderRevokedAt(), isNull);
    expect(await lastRevokedAt(), await revocationOf(e4));
  });

  group('lastRevokedAt counts every revocation', () {
    test('E3, whose record carried a key package, revoked', () async {
      final e3 = await enrolled('e3', {'app': 'rw'},
          metadata: {'keyPackage': aKeyPackage});

      await revoke(e3);

      expect(await lastRevokedAt(), await revocationOf(e3));
    });

    test('E2, whose record has never carried a key package, revoked', () async {
      final e2 = await enrolled('e2', {'app': 'rw'});

      await revoke(e2);

      expect(await lastRevokedAt(), await revocationOf(e2));
    });

    test(
        'E2, whose record has never carried a key package, superseded by its '
        "retrofit's first authentication", () async {
      final e2 = await enrolled('e2', {'app': 'rw'});
      final (successor, key) = await retrofit(e2);

      await authenticateAs(successor, key);

      expect(await lastRevokedAt(), await revocationOf(e2));
    });
  });
}

/// An [EnrollmentManager] that reports when a write first asks it to mark a
/// key holder, before it waits for the enrollment-mutation section.
class _ReportsArrival extends EnrollmentManager {
  _ReportsArrival(super.keyStore, super.atSign);

  final Completer<void> arrived = Completer<void>();

  @override
  Future<T> writeAsKeyHolder<T>(
      String enrollmentId, Future<T> Function() write) {
    final Future<T> result = super.writeAsKeyHolder(enrollmentId, write);
    if (!arrived.isCompleted) arrived.complete();
    return result;
  }
}
