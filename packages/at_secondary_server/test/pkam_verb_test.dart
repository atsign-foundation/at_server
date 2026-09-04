import 'dart:collection';
import 'dart:convert';

import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() async {
  AtKeyValueStore<String, AtData, AtMetaData?> mockKeyStore =
      MockAtKeyValueStore();

  verbTestsSetUpLogging();

  group('pkam tests', () {
    test('test for pkam correct syntax', () {
      var verb = Pkam();
      var command = 'pkam:edgvb1234';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['signature'], 'edgvb1234');
    });

    test('test for incorrect syntax', () {
      var verb = Pkam();
      var command = 'pkam@:edgvb1234';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test pkam accept', () {
      var command = 'pkam:abc123';
      var handler = PkamVerbHandler(mockKeyStore);
      expect(handler.accept(command), true);
    });

    test('test pkam accept invalid keyword', () {
      var command = 'pkamer:';
      var handler = PkamVerbHandler(mockKeyStore);
      expect(handler.accept(command), false);
    });

    test('test pkam verb handler getVerb', () {
      var verbHandler = PkamVerbHandler(mockKeyStore);
      var verb = verbHandler.getVerb();
      expect(verb is Pkam, true);
    });

    test('test pkam verb - upper case with spaces', () {
      var command = 'PK AM:';
      command = SecondaryUtil.convertCommand(command);
      var handler = PkamVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });
  });

  group('apkam tests', () {
    late EnrollDataStoreValue enrollData;
    late PkamVerbHandler pkamVerbHandler;

    setUp(() {
      enrollData = EnrollDataStoreValue(
          'enrollId', 'unit_test', 'test_device', 'dummy_public_key');
      AtSecondaryServerImpl.getInstance().enrollmentManager =
          enMgr = EnrollmentManager(mockKeyStore, alice);
      enMgr.logger.level = 'shout';
      mockKeyStore.preRemoveHooks.add(enMgr.preRemoveHook);
      mockKeyStore.postRemoveHooks.add(enMgr.postRemoveHook);
      pkamVerbHandler = PkamVerbHandler(mockKeyStore);
    });

    test('verify apkam behaviour - case: enrollment approved ', () async {
      enrollData.approval = EnrollApproval('approved');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.verifyEnrollmentIsActive('enrollId', alice);
      expect(apkamResult.publicKey, 'dummy_public_key');
    });

    test('verify apkam behaviour - case: enrollment revoked ', () async {
      enrollData.approval = EnrollApproval('revoked');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.verifyEnrollmentIsActive('enrollId', alice);
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0027');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is revoked');
    });

    test('verify apkam behaviour - case: enrollment pending ', () async {
      enrollData.approval = EnrollApproval('pending');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.verifyEnrollmentIsActive('enrollId', alice);
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0026');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is pending');
    });

    test('verify apkam behaviour - case: enrollment denied ', () async {
      enrollData.approval = EnrollApproval('denied');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.verifyEnrollmentIsActive('enrollId', alice);
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0025');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is denied');
    });

    test('verify apkam behaviour - case: enrollment expired ', () async {
      EnrollDataStoreValue enValue = EnrollDataStoreValue(
          'dummy-session', 'app-name', 'my-device', 'dummy-public-key')
        ..namespaces = {'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);

      String enId = Uuid().v4();
      String ek = enMgr.buildEnrollmentKey(enId);

      // Permissive on purpose, so that the verifyNever below is what
      // reports a removal. An unstubbed `remove` returns null through
      // noSuchMethod and blows up on the await, failing this test on a
      // TypeError that names neither the removal nor the assertion.
      when(() => mockKeyStore.remove(any(),
          skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async => null);

      when(() => mockKeyStore.get(ek)).thenAnswer((invocation) => Future.value(
          AtData()
            ..data = jsonEncode(enValue.toJson())
            ..metaData = (AtMetaData()
              ..expiresAt =
                  DateTime.now().subtract(Duration(milliseconds: 1)))));

      var apkamResult =
          await pkamVerbHandler.verifyEnrollmentIsActive(enId, alice);
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0028');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: $enId is expired or invalid');

      // A read path must not write: this check runs on every verb command,
      // outside the enrollment-mutation critical section, so a removal here
      // would mutate the store while another mutation is in flight.
      verifyNever(
          () => mockKeyStore.remove(any(), skipCommit: any(named: 'skipCommit')));
    });
  });

  group('A group of tests related to apkam keys expiry', () {
    Response response = Response();
    late String enrollmentId;

    setUp(() async => await verbTestsSetUp());

    tearDown(() async => await verbTestsTearDown());

    test('A test to verify pkam verb fails when apkam keys are expired',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-session', 'app-name', 'my-device', 'dummy-public-key');
      enrollDataStoreValue.namespaces = {'wavi': 'rw'};
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.approved.name);
      enrollDataStoreValue.apkamKeysExpiryDuration = Duration(milliseconds: 1);

      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(
          keyName,
          AtData()
            ..data = jsonEncode(enrollDataStoreValue.toJson())
            ..metaData = (AtMetaData()..ttl = 1));

      String pkamCommand =
          'pkam:enrollmentid:$enrollmentId:dummy-pkam-challenge';

      HashMap<String, String?> pkamVerbParams =
          getVerbParam(VerbSyntax.pkam, pkamCommand);

      PkamVerbHandler pkamVerbHandler = PkamVerbHandler(keyValueStore);
      await pkamVerbHandler.processVerb(
          response, pkamVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0028');
      expect(response.errorMessage,
          'enrollment_id: $enrollmentId is expired or invalid');
    });
  });

  group('legacy PKAM: the flat credential', () {
    setUp(() async => await verbTestsSetUp());

    tearDown(() async => await verbTestsTearDown());

    test('authenticates with NO enrollment id, migrates into primary, and '
        'keeps working', () async {
      // The flat credential at `at_pkam_publickey` is the only credential
      // some atSigns in the field hold. The first legacy login migrates it
      // into the `primary` enrollment and deletes the flat key; the second
      // verifies against that record.
      //
      // ⚠️ The key is deliberately not re-seeded between the two logins:
      // re-seeding would paper over a migration that left nothing to verify
      // against.
      final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = base64Encode(mlDsa.publicKey),
          skipCommit: true);

      Future<Response> authenticate(String sessionId) async {
        const challenge = 'a-per-connection-challenge';
        await keyValueStore.put(
            'private:$sessionId$alice', AtData()..data = challenge);
        final signature = await MlDsa65PureDartAlgo().signBytes(
            Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
            secretKey: mlDsa.secretKey);
        inboundConnection.metaData
          ..isAuthenticated = false
          ..enrollmentId = null
          ..sessionID = sessionId;
        final r = Response();
        await PkamVerbHandler(keyValueStore).processVerb(
          r,
          getVerbParam(VerbSyntax.pkam,
              'pkam:signingAlgo:mldsa65:${base64Encode(signature)}'),
          inboundConnection,
        );
        return r;
      }

      expect((await authenticate('first')).data, 'success',
          reason: 'a flat keyfile is the only credential some atSigns have');
      expect(inboundConnection.metaData.enrollmentId,
          EnrollmentManager.primaryEnrollmentId,
          reason: 'the connection carries primary: the flat key has become '
              'a record, so the login is judged as that record from here on');
      expect(inboundConnection.metaData.authType, AuthType.pkamLegacy);
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isFalse,
          reason: 'one credential and one record: the flat key is absorbed '
              'by the login that proved it');

      expect((await authenticate('second')).data, 'success',
          reason: 'and it must still work — a keypair that stops '
              'authenticating on migration is not a credential');
      expect(inboundConnection.metaData.enrollmentId,
          EnrollmentManager.primaryEnrollmentId);
    });
  });
}
