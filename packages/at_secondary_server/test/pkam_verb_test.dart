import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
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
      // dummy enroll value
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

      // PERMISSIVE, and then verified NEVER CALLED. This test used to stub
      // four exact removes — the enrollment key, its two encryption keys and
      // the legacy APKAM public key — because reading an expired enrollment
      // used to REAP it. Three of those four stubbed the key the production
      // code was about to build by calling the very builder that builds it,
      // so they matched whatever that builder produced and could not fail;
      // and the reap they were written for is gone, so as exact stubs they
      // matched nothing at all.
      //
      // A permissive stub is what makes the assertion below say something. An
      // unstubbed `remove` on a mock returns null through noSuchMethod and
      // blows up on the await, so a reap that came back would fail this test
      // on a TypeError naming neither the reap nor this assertion — red for
      // the wrong reason. Stubbed, a reap SUCCEEDS silently, and verifyNever
      // is then the only thing that reports it.
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

      // A READ path must not write. An authorisation check runs on every verb
      // command, outside the atSign's enrollment-mutation critical section, so
      // a reap here is a store mutation taken by a caller that has decided
      // nothing while another mutation is in flight — and for the housekeeping
      // record it is worse than untidy, because removing it fires the
      // pre-remove hook and takes `at_pkam_publickey` with it. An
      // authorisation check would retire the atSign's legacy credential.
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
}
