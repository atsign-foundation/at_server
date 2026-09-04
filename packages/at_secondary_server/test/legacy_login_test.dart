import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// A legacy `pkam:`, one carrying no enrollment id, authenticates as
/// `primary`, the enrollment the flat legacy credential migrates into. The
/// first such login against a flat key still in the store absorbs it, and
/// every later login verifies against `primary`'s recorded key.
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  const String primary = EnrollmentManager.primaryEnrollmentId;

  late dynamic legacyPair;
  late String legacyPublicKey;

  setUp(() async {
    legacyPair = await MlDsa65PureDartAlgo().generateKeyPair();
    legacyPublicKey = base64Encode(legacyPair.publicKey);
  });

  Future<void> installFlatKey([String? value]) => keyValueStore.put(
      AtConstants.atPkamPublicKey, AtData()..data = value ?? legacyPublicKey,
      skipCommit: true);

  /// A legacy `pkam:` on a fresh connection, signed with [pair] (the legacy
  /// keypair by default), naming no enrollment id. [connection] defaults to
  /// the shared one.
  Future<Response> legacyLogin(String sessionId,
      {dynamic pair, DummyInboundConnection? connection}) async {
    pair ??= legacyPair;
    final DummyInboundConnection conn = connection ?? inboundConnection;
    const challenge = 'a-per-connection-challenge';
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final signature = await MlDsa65PureDartAlgo().signBytes(
        Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
        secretKey: pair.secretKey);
    conn.metaData
      ..isAuthenticated = false
      ..authType = null
      ..enrollmentId = null
      ..sessionID = sessionId;
    final r = Response();
    try {
      await PkamVerbHandler(keyValueStore).processVerb(
        r,
        getVerbParam(VerbSyntax.pkam,
            'pkam:signingAlgo:mldsa65:${base64Encode(signature)}'),
        conn,
      );
    } on AtException catch (e) {
      r.isError = true;
      r.errorMessage = '${e.runtimeType}: ${e.message}';
    }
    return r;
  }

  Future<void> setPrimaryStatus(EnrollmentStatus status) async {
    final String ek = enMgr.buildEnrollmentKey(primary);
    final AtData record = (await keyValueStore.get(ek))!;
    final EnrollDataStoreValue v =
        EnrollDataStoreValue.fromJson(jsonDecode(record.data!))
          ..approval = EnrollApproval(status.name);
    record.data = jsonEncode(v.toJson());
    await enMgr.put(primary, record, status);
  }

  group('the first legacy login migrates the flat key', () {
    test('verifies against the flat key, absorbs it, and carries primary',
        () async {
      await installFlatKey();

      final r = await legacyLogin('first');

      expect(r.data, 'success', reason: r.errorMessage);
      expect(inboundConnection.metaData.enrollmentId, primary,
          reason: 'the connection carries primary from here on, so every '
              'path keyed on the enrollment a connection carries applies');
      expect(inboundConnection.metaData.authType, AuthType.pkamLegacy);
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isFalse,
          reason: 'one credential and one record: the flat key is gone');
      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, legacyPublicKey);
      expect(v.signingAlgo, 'mldsa65',
          reason: 'recorded as what the wire proved the key to be, so later '
              'logins are judged under the algorithm the key really is');
      expect(v.isRootEnrollment, isTrue);
    });

    test('a second login verifies against primary\'s recorded key', () async {
      await installFlatKey();
      expect((await legacyLogin('first')).data, 'success');

      final r = await legacyLogin('second');

      expect(r.data, 'success', reason: r.errorMessage);
      expect(inboundConnection.metaData.enrollmentId, primary);
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isFalse,
          reason: 'and nothing re-created the flat key');
    });

    test('naming primary on the wire is the same login', () async {
      await installFlatKey();
      expect((await legacyLogin('first')).data, 'success');

      const sessionId = 'named';
      const challenge = 'a-per-connection-challenge';
      await keyValueStore.put(
          'private:$sessionId$alice', AtData()..data = challenge);
      final signature = await MlDsa65PureDartAlgo().signBytes(
          Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
          secretKey: legacyPair.secretKey);
      inboundConnection.metaData
        ..isAuthenticated = false
        ..enrollmentId = null
        ..sessionID = sessionId;
      final r = Response();
      await PkamVerbHandler(keyValueStore).processVerb(
        r,
        getVerbParam(
            VerbSyntax.pkam,
            'pkam:enrollmentId:primary:'
            '${base64Encode(signature)}'),
        inboundConnection,
      );

      expect(r.data, 'success', reason: r.errorMessage);
      expect(inboundConnection.metaData.enrollmentId, primary);
      expect(inboundConnection.metaData.authType, AuthType.apkam,
          reason: 'named on the wire it is an APKAM login of an ordinary '
              'record — the same record');
    });

    test('a flat key that does not verify is refused, and nothing is minted',
        () async {
      await installFlatKey();
      final other = await MlDsa65PureDartAlgo().generateKeyPair();

      final r = await legacyLogin('wrong', pair: other);

      expect(r.isError, isTrue);
      expect(r.errorMessage, contains('pkam authentication failed'));
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
          reason: 'the flat key is absorbed by a login that proved it, not by '
              'one that failed to');
      expect(await enMgr.primaryEnrollment(), isNull);
    });

    test('two concurrent first logins mint primary once', () async {
      await installFlatKey();
      final one = DummyInboundConnection();
      final two = DummyInboundConnection();

      final gate = Completer<void>();
      final holder = enMgr.serialiseMutation(() => gate.future);
      final logins = [
        legacyLogin('race-one', connection: one),
        legacyLogin('race-two', connection: two),
      ];
      await Future<void>.delayed(Duration(milliseconds: 100));

      final mintedDuringHold = await enMgr.primaryEnrollment();
      final flatKeyDuringHold =
          await keyValueStore.exists(AtConstants.atPkamPublicKey);

      gate.complete();
      final results = await Future.wait(logins);
      await holder;

      expect(mintedDuringHold, isNull,
          reason: 'both logins verified their signature outside the section '
              'and must be parked at the admission, which is the '
              'read-decide-write that mints primary');
      expect(flatKeyDuringHold, isTrue,
          reason: 'and neither absorbed the flat key while the section was '
              'held');
      expect(results.map((r) => r.data), ['success', 'success'],
          reason: 'the login that waited on the section finds no flat key '
              'and verifies against the record the other wrote');
      expect(one.metaData.enrollmentId, primary,
          reason: 'both connections are admitted as primary, not just the '
              'login that happened to mint the record');
      expect(two.metaData.enrollmentId, primary,
          reason: 'both connections are admitted as primary, not just the '
              'login that happened to mint the record');
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isFalse);
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          legacyPublicKey);
      final roster = await enMgr.getAllEnrollmentKeys(includeExpired: true);
      expect(roster, [enMgr.buildEnrollmentKey(primary)],
          reason: 'one record, whichever login minted it');
    });
  });

  group('primary is judged like any enrollment', () {
    test('a revoked primary refuses with AT0027', () async {
      await installFlatKey();
      expect((await legacyLogin('first')).data, 'success');
      await setPrimaryStatus(EnrollmentStatus.revoked);

      final r = await legacyLogin('after-revoke');

      expect(r.isError, isTrue);
      expect(r.errorCode, 'AT0027');
      expect(r.errorMessage, 'enrollment_id: primary is revoked',
          reason: 'the refusal names no other enrollment');
      expect(inboundConnection.metaData.isAuthenticated, isFalse);
    });

    test('a login that absorbs into a revoked primary is refused too',
        () async {
      await installFlatKey();
      expect((await legacyLogin('first')).data, 'success');
      await setPrimaryStatus(EnrollmentStatus.revoked);
      final rotated = await MlDsa65PureDartAlgo().generateKeyPair();
      await installFlatKey(base64Encode(rotated.publicKey));

      final r = await legacyLogin('rotated', pair: rotated);

      expect(r.isError, isTrue);
      expect(r.errorCode, 'AT0027');
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isFalse,
          reason: 'absorbed all the same, so no flat key is left behind');
    });

    test('with neither a flat key nor a primary, the refusal names the remedy',
        () async {
      final r = await legacyLogin('nothing');

      expect(r.isError, isTrue);
      expect(r.errorMessage,
          contains('this atSign has no legacy PKAM credential'));
    });

    test('the key the record holds is what verifies, not the flat key that '
        'was', () async {
      await installFlatKey();
      expect((await legacyLogin('first')).data, 'success');
      final other = await MlDsa65PureDartAlgo().generateKeyPair();

      final r = await legacyLogin('other-key', pair: other);

      expect(r.isError, isTrue);
      expect(r.errorMessage, contains('pkam authentication failed'));
    });
  });

  group('a legacy connection carrying primary', () {
    test('sends enroll:request as a retrofit of primary', () async {
      await installFlatKey();
      expect((await legacyLogin('first')).data, 'success');
      final EnrollVerbHandler evh =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      final EnrollParams ep = EnrollParams()
        ..appName = 'phone'
        ..deviceName = 'device'
        ..apkamPublicKey = 'a fresh key for the successor';

      final r = Response();
      await evh.processVerb(
          r,
          getVerbParam(
              VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
          inboundConnection);

      expect(r.isError, isFalse, reason: r.errorMessage);
      final Map m = jsonDecode(r.data!);
      expect(m['status'], EnrollmentStatus.approved.name,
          reason: 'auto-approved under primary\'s authority');
      final EnrollDataStoreValue successor =
          await enMgr.getEnrollmentById(m['enrollmentId']);
      expect(successor.retrofitPredecessorEnrollmentId, primary);
      expect(successor.namespaces, {'*': 'rw', '__manage': 'rw'},
          reason: 'primary\'s grants, inherited');
      expect(successor.parentEnrollmentId, isNull,
          reason: 'copied from primary, which has no parent');
    });
  });
}
