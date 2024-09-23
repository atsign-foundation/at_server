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

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();

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
      print('result : $result');
      expect(result, true);
    });
  });

  group('apkam tests', () {
    late EnrollDataStoreValue enrollData;
    late PkamVerbHandler pkamVerbHandler;

    setUpAll(() {
      // dummy enroll value
      enrollData = EnrollDataStoreValue(
          'enrollId', 'unit_test', 'test_device', 'dummy_public_key');
      AtSecondaryServerImpl.getInstance().enrollmentManager =
          EnrollmentManager(mockKeyStore);
      pkamVerbHandler = PkamVerbHandler(mockKeyStore);
    });

    test('verify apkam behaviour - case: enrollment approved ', () async {
      enrollData.approval = EnrollApproval('approved');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
      expect(apkamResult.publicKey, 'dummy_public_key');
    });

    test('verify apkam behaviour - case: enrollment revoked ', () async {
      enrollData.approval = EnrollApproval('revoked');
      AtData data = AtData()..data = jsonEncode(enrollData.toJson());
      when(() => mockKeyStore.get(any()))
          .thenAnswer((invocation) async => data);

      var apkamResult =
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
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
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
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
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0025');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is denied');
    });

    test('verify apkam behaviour - case: enrollment expired ', () async {
      enrollData.approval = EnrollApproval('denied');
      when(() => mockKeyStore.get(any()))
          .thenThrow(KeyNotFoundException('key not found'));

      var apkamResult =
          await pkamVerbHandler.handleApkamVerification('enrollId', '@alice');
      expect(apkamResult.response.isError, true);
      expect(apkamResult.response.errorCode, 'AT0028');
      expect(apkamResult.response.errorMessage,
          'enrollment_id: enrollId is expired or invalid');
    });
  });

  group('A group of tests related to apkam keys expiry', () {
    Response response = Response();
    late String enrollmentId;

    setUp(() async {
      await verbTestsSetUp();
    });

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

      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName,
          AtData()
            ..data = jsonEncode(enrollDataStoreValue.toJson())
            ..metaData = (AtMetaData()..ttl = 1));

      String pkamCommand =
          'pkam:enrollmentid:$enrollmentId:dummy-pkam-challenge';

      HashMap<String, String?> pkamVerbParams =
          getVerbParam(VerbSyntax.pkam, pkamCommand);

      PkamVerbHandler pkamVerbHandler = PkamVerbHandler(secondaryKeyStore);
      await pkamVerbHandler.processVerb(
          response, pkamVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0028');
      expect(response.errorMessage,
          'enrollment_id: $enrollmentId is expired or invalid');
    });
  });
}
