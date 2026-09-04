import 'dart:async';
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
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// A `pkam:` login reads the enrollment it rests on, verifies a signature
/// against the key that read returned, and only then admits the connection.
/// Admission re-reads inside the enrollment-mutation section, so a store that
/// changed while the signature was being verified is the store the decision
/// is made on.
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
  const String challenge = 'a-per-connection-challenge';

  /// Takes the atSign's enrollment-mutation section and holds it until the
  /// returned completer completes.
  (Completer<void>, Future<void>) holdTheSection() {
    final gate = Completer<void>();
    return (gate, enMgr.serialiseMutation(() => gate.future));
  }

  /// Writes the challenge [sessionId] will be asked for and returns the
  /// signature over it, so the login itself does nothing but send.
  Future<String> armChallenge(String sessionId, dynamic pair) async {
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final signature = await MlDsa65PureDartAlgo().signBytes(
        Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
        secretKey: pair.secretKey);
    return base64Encode(signature);
  }

  /// Sends [command] on a fresh, unauthenticated connection.
  Future<Response> send(String sessionId, String command) async {
    inboundConnection.metaData
      ..isAuthenticated = false
      ..authType = null
      ..enrollmentId = null
      ..sessionID = sessionId;
    final r = Response();
    try {
      await PkamVerbHandler(keyValueStore).processVerb(
        r,
        getVerbParam(VerbSyntax.pkam, command),
        inboundConnection,
      );
    } on AtException catch (e) {
      r.isError = true;
      r.errorMessage = '${e.runtimeType}: ${e.message}';
    }
    return r;
  }

  /// Waits until [sessionId]'s login has spent its challenge, which it does
  /// after the read the signature is verified against and before the section.
  Future<void> untilPastTheFirstRead(String sessionId) async {
    final String key = 'private:$sessionId$alice';
    for (int i = 0; i < 500; i++) {
      if (!await keyValueStore.exists(key)) return;
      await Future<void>.delayed(Duration(milliseconds: 10));
    }
    fail('the login never spent its challenge, so it never got past the '
        'read this test has to interfere after — interfering earlier would '
        'be refused by the first read and prove nothing about the re-check');
  }

  Future<EnrollDataStoreValue> recordOf(String enId) =>
      enMgr.getEnrollmentById(enId);

  /// Writes [enId] back with [status], as a competing verb would.
  Future<void> setStatus(String enId, EnrollmentStatus status) async {
    final String ek = enMgr.buildEnrollmentKey(enId);
    final AtData record = (await keyValueStore.get(ek))!;
    final EnrollDataStoreValue v =
        EnrollDataStoreValue.fromJson(jsonDecode(record.data!))
          ..approval = EnrollApproval(status.name);
    record.data = jsonEncode(v.toJson());
    await enMgr.put(enId, record, status);
  }

  group('an APKAM login whose enrollment stops serving mid-flight', () {
    late dynamic pair;
    late String enrollmentId;

    setUp(() async {
      pair = await MlDsa65PureDartAlgo().generateKeyPair();
      enrollmentId = Uuid().v4();
      final EnrollDataStoreValue value = EnrollDataStoreValue(
          'a-session', 'app', 'device', base64Encode(pair.publicKey))
        ..namespaces = {'wavi': 'rw'}
        ..signingAlgo = 'mldsa65'
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await enMgr.put(enrollmentId, AtData()..data = jsonEncode(value.toJson()),
          EnrollmentStatus.approved);
    });

    String commandFor(String signature) =>
        'pkam:signingAlgo:mldsa65:enrollmentId:$enrollmentId:$signature';

    test('is refused on the state the section finds, not the state it read',
        () async {
      const String sessionId = 'revoked-mid-flight';
      final String signature = await armChallenge(sessionId, pair);

      final (gate, holder) = holdTheSection();
      final Future<Response> login = send(sessionId, commandFor(signature));
      await untilPastTheFirstRead(sessionId);
      await setStatus(enrollmentId, EnrollmentStatus.revoked);
      gate.complete();
      final Response r = await login;
      await holder;

      expect(await recordOf(enrollmentId).then((v) => v.approval?.state),
          EnrollmentStatus.revoked.name,
          reason: 'precondition: the revoke really did land while the login '
              'was parked at the section');
      expect(r.isError, isTrue,
          reason: 'the enrollment stopped serving after the read the '
              'signature was checked against, so the admission must be made '
              'on the re-read rather than on the stale answer');
      expect(r.errorCode, 'AT0027',
          reason: 'the refusal is the revoked enrollment\'s own refusal');
      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'a revoked enrollment must not leave an authenticated '
              'connection behind');
      expect(inboundConnection.metaData.enrollmentId, isNull,
          reason: 'nor a connection carrying its id');
    });

    test('POSITIVE CONTROL: the same sequence with nothing interfering is '
        'admitted', () async {
      const String sessionId = 'undisturbed';
      final String signature = await armChallenge(sessionId, pair);

      final (gate, holder) = holdTheSection();
      final Future<Response> login = send(sessionId, commandFor(signature));
      await untilPastTheFirstRead(sessionId);
      gate.complete();
      final Response r = await login;
      await holder;

      expect(r.data, 'success',
          reason: 'parking at the section refuses nothing by itself, so the '
              'refusal above is about the revoke and not about the hold');
      expect(inboundConnection.metaData.isAuthenticated, isTrue);
      expect(inboundConnection.metaData.enrollmentId, enrollmentId);
    });
  });

  group('a legacy login whose primary is rotated mid-flight', () {
    late dynamic verifiedPair;

    /// An atSign whose `primary` holds [verifiedPair]'s key, reached the way
    /// a real one does: a flat credential absorbed by the login that proved
    /// it.
    setUp(() async {
      verifiedPair = await MlDsa65PureDartAlgo().generateKeyPair();
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = base64Encode(verifiedPair.publicKey),
          skipCommit: true);
      const String sessionId = 'the-migrating-login';
      final String signature = await armChallenge(sessionId, verifiedPair);
      final Response r = await send(
          sessionId, 'pkam:signingAlgo:mldsa65:$signature');
      expect(r.data, 'success', reason: 'precondition: ${r.errorMessage}');
      expect((await recordOf(primary)).apkamPublicKey,
          base64Encode(verifiedPair.publicKey),
          reason: 'precondition: primary holds the key later logins verify '
              'against');
    });

    /// Puts [pair]'s key on `primary`, as a competing legacy login absorbing
    /// a rotated flat credential would.
    Future<void> rotatePrimaryOnto(dynamic pair) async {
      final String ek = enMgr.buildEnrollmentKey(primary);
      final AtData record = (await keyValueStore.get(ek))!;
      final EnrollDataStoreValue v =
          EnrollDataStoreValue.fromJson(jsonDecode(record.data!))
            ..apkamPublicKey = base64Encode(pair.publicKey)
            ..signingAlgo = 'mldsa65';
      record.data = jsonEncode(v.toJson());
      await enMgr.put(primary, record, EnrollmentStatus.approved);
    }

    test('is refused, because the key that verified is no longer the key '
        'primary holds', () async {
      const String sessionId = 'rotated-mid-flight';
      final String signature = await armChallenge(sessionId, verifiedPair);
      final rotatedOnto = await MlDsa65PureDartAlgo().generateKeyPair();

      final (gate, holder) = holdTheSection();
      final Future<Response> login =
          send(sessionId, 'pkam:signingAlgo:mldsa65:$signature');
      await untilPastTheFirstRead(sessionId);
      await rotatePrimaryOnto(rotatedOnto);
      gate.complete();
      final Response r = await login;
      await holder;

      expect((await recordOf(primary)).apkamPublicKey,
          base64Encode(rotatedOnto.publicKey),
          reason: 'precondition: the rotation really did land while the '
              'login was parked at the section');
      expect(r.isError, isTrue,
          reason: 'the signature proved a key primary no longer holds, so '
              'admitting on it would authenticate a retired credential');
      expect(r.errorMessage, contains('pkam authentication failed'),
          reason: 'refused as the bad signature it now is');
      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'and the connection is left unauthenticated');
      expect(inboundConnection.metaData.enrollmentId, isNull,
          reason: 'carrying no enrollment id');
    });

    test('POSITIVE CONTROL: the same sequence with nothing interfering is '
        'admitted', () async {
      const String sessionId = 'undisturbed-legacy';
      final String signature = await armChallenge(sessionId, verifiedPair);

      final (gate, holder) = holdTheSection();
      final Future<Response> login =
          send(sessionId, 'pkam:signingAlgo:mldsa65:$signature');
      await untilPastTheFirstRead(sessionId);
      gate.complete();
      final Response r = await login;
      await holder;

      expect(r.data, 'success',
          reason: 'parking at the section refuses nothing by itself, so the '
              'refusal above is about the rotation and not about the hold');
      expect(inboundConnection.metaData.isAuthenticated, isTrue);
      expect(inboundConnection.metaData.enrollmentId, primary);
      expect(inboundConnection.metaData.authType, AuthType.pkamLegacy);
    });
  });
}
