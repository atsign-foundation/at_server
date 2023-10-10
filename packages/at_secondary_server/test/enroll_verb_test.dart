import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('A group of tests to verify enroll request operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enroll requests get different enrollment ids',
        () async {
      Response response = Response();
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_1 = jsonDecode(response.data!)['enrollmentId'];
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      print('OTP: ${response.data}');
      // Enroll request 2
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_2 = jsonDecode(response.data!)['enrollmentId'];

      expect(enrollmentId_1, isNotEmpty);
      expect(enrollmentId_2, isNotEmpty);
      expect(enrollmentId_1 == enrollmentId_2, false);
    });

    test(
        'A test to verify enrollment of CRAM auth connection have __manage and * namespaces added to enrollment value',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().authType = AuthType.cram;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String enrollmentKey =
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      var enrollmentValue =
          await enrollVerbHandler.getEnrollDataStoreValue(enrollmentKey);
      expect(enrollmentValue.namespaces.containsKey('__manage'), true);
      expect(enrollmentValue.namespaces.containsKey('*'), true);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests to verify enroll list operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enrollment list', () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice1","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().authType = AuthType.cram;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentList = 'enroll:list';
      verbParams = getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollListResponse = jsonDecode(response.data!);
      var testResponse = enrollListResponse[
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'];
      assert(response.data!.contains(enrollmentId));
      expect(testResponse['appName'], 'wavi');
      expect(testResponse['deviceName'], 'mydevice1');
      expect(testResponse['namespace']['wavi'], 'r');
      expect(testResponse['approval'], 'approved');
    });

    test('A test to verify enrollment list with enrollmentId is populated',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice2","namespaces":{"wavi":"rw"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentList = 'enroll:list';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = enrollmentId;
      verbParams = getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollListResponse = jsonDecode(response.data!);
      var testResponse = enrollListResponse[
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'];
      assert(response.data!.contains(enrollmentId));
      expect(testResponse['appName'], 'wavi');
      expect(testResponse['deviceName'], 'mydevice2');
      expect(testResponse['namespace']['wavi'], 'rw');
      expect(testResponse['approval'], 'pending');
    });

    test(
        'A test to verify enrollment list without __manage namespace returns enrollment info of given enrollmentId',
        () async {
      Response response = Response();
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      // Enroll request - 1 -------------------------------------
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentIdOne = jsonDecode(response.data!)['enrollmentId'];
      response = Response();
      // Fetch OTP ------------------------------------------------
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String? otp = response.data;
      print('OTP: $otp');
      response = Response();
      // Enroll request - 2 --------------------------------------------
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","otp":"$otp","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      response = Response();
      // Approve 2nd enrollment -----------------------------------------
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      response = Response();
      // Enroll list ----------------------------------------------------
      String enrollmentList = 'enroll:list';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = enrollmentId;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollListResponse = jsonDecode(response.data!);
      var testResponse = enrollListResponse[
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'];
      expect(testResponse['appName'], 'wavi');
      expect(testResponse['deviceName'], 'mydevice');
      expect(testResponse['namespace']['wavi'], 'r');
      expect(testResponse['approval'], 'approved');
      expect(
          enrollListResponse.containsKey(
              '$enrollmentIdOne.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'),
          false);
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('verify enroll:update behaviour', () {
    late EnrollVerbHandler enrollVerbHandler;

    setUpAll(() async {
      await verbTestsSetUp();
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      inboundConnection.getMetaData().sessionID = 'enroll:update:session_id';
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().authType = AuthType.apkam;
    });

    Future<String> createAndApproveEnrollment() async {
      inboundConnection.getMetaData().authType = AuthType.cram;
      Response response = Response();
      String command =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      //reset inbound connection details
      inboundConnection.getMetaData().authType = AuthType.apkam;
      return jsonDecode(response.data!)['enrollmentId'];
    }

    test('verify enroll:update behaviour without auth', () async {
      inboundConnection.getMetaData().isAuthenticated = false;
      String command =
          'enroll:update:{"enrollmentId":"dummy_enroll_id","namespaces":{"update":"rw"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((e) => e is UnAuthenticatedException)));
      inboundConnection.getMetaData().isAuthenticated = true;
    });

    test('verify enroll:update creates a request with supplementary namespace',
        () async {
      String enrollId = await createAndApproveEnrollment();
      String command =
          'enroll:update:{"enrollmentId":"$enrollId","namespaces":{"update":"r"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollId);
      expect(jsonDecode(response.data!)['status'], 'pending');
    });

    test('verify enroll:update behaviour with invalid params', () async {
      String command = 'enroll:update:{"namespaces":{"update":"rw"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((e) => e is IllegalArgumentException)));
    });

    test('verify enroll:update behavior with invalid enrollmentId', () async {
      String dummyEnrollId = 'dummy_enroll_id';
      String command =
          'enroll:update:{"enrollmentId":"$dummyEnrollId","namespaces":{"update":"r"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) => e is AtInvalidEnrollmentException)));
    });

    test('verify enroll:update behaviour on expired enrollment', () async {
      // create and approve enrollment
      String enrollId = await createAndApproveEnrollment();
      // set the enrollment status as expired
      String enrollmentKey =
          enrollVerbHandler.getEnrollmentKey(enrollId, currentAtsign: '@alice');
      EnrollDataStoreValue existingEnrollValue =
          await enrollVerbHandler.getEnrollDataStoreValue(enrollmentKey);
      existingEnrollValue.approval!.state = EnrollStatus.expired.name;
      AtData atData = AtData();
      atData.data = jsonEncode(existingEnrollValue);
      atData.metaData = AtMetaData()
        ..expiresAt = DateTime.now().toUtc().subtract(Duration(hours: 10));
      await secondaryKeyStore.put(enrollmentKey, atData);
      // update the expired enrollment
      String command =
          'enroll:update:{"enrollmentId":"$enrollId","namespaces":{"update":"r"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(isA<AtInvalidEnrollmentException>()));
    });

    test('verify enroll:update behaviour on revoked enrollment', () async {
      // create and approve enrollment
      String enrollId = await createAndApproveEnrollment();
      // set the enrollment status as expired
      String enrollmentKey =
          enrollVerbHandler.getEnrollmentKey(enrollId, currentAtsign: '@alice');
      EnrollDataStoreValue existingEnrollValue =
          await enrollVerbHandler.getEnrollDataStoreValue(enrollmentKey);
      // set the existing state as revoked
      existingEnrollValue.approval!.state = EnrollStatus.revoked.name;
      AtData atData = AtData();
      atData.data = jsonEncode(existingEnrollValue);
      atData.metaData = AtMetaData();
      // store the modified enrollment value to the actual enrollment key
      await secondaryKeyStore.put(enrollmentKey, atData);
      // update the expired enrollment
      String command =
          'enroll:update:{"enrollmentId":"$enrollId","namespaces":{"update":"r"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0030');
      expect(response.errorMessage,
          'Enrollment_id: $enrollId is revoked. Only approved enrollments can be updated');
    });

    test('verify enroll:update behaviour on denied enrollment', () async {
      // create and approve enrollment
      String enrollId = await createAndApproveEnrollment();
      // set the enrollment status as expired
      String enrollmentKey =
          enrollVerbHandler.getEnrollmentKey(enrollId, currentAtsign: '@alice');
      EnrollDataStoreValue existingEnrollValue =
          await enrollVerbHandler.getEnrollDataStoreValue(enrollmentKey);
      existingEnrollValue.approval!.state = EnrollStatus.denied.name;
      AtData atData = AtData();
      atData.data = jsonEncode(existingEnrollValue);
      atData.metaData = AtMetaData();
      await secondaryKeyStore.put(enrollmentKey, atData);
      // update the expired enrollment
      String command =
          'enroll:update:{"enrollmentId":"$enrollId","namespaces":{"update":"r"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0030');
      expect(response.errorMessage,
          'Enrollment_id: $enrollId is denied. Only approved enrollments can be updated');
    });

    test('verify enroll:update behaviour when enrollment request expires',
        () async {
      enrollVerbHandler.enrollmentExpiryInMills = 1;
      // create and approve enrollment
      String enrollId = await createAndApproveEnrollment();
      // enrollment update request
      String command =
          'enroll:update:{"enrollmentId":"$enrollId","namespaces":{"update":"rw"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      // approve enrollment update request
      response = Response();
      command = 'enroll:approve:{"enrollmentId":"$enrollId"}';
      verbParams = getVerbParam(VerbSyntax.enroll, command);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0030');
      expect(response.errorMessage,
          'Enrollment_id: $enrollId is approved. Only pending enrollments can be approved');
      // reset enrollments expiry duration
      enrollVerbHandler.enrollmentExpiryInMills =
          Duration(hours: AtSecondaryConfig.enrollmentExpiryInHours)
              .inMilliseconds;
    });

    test(
        'verify that approved enrollment update request updated the namespaces',
        () async {
      // create and approve enrollment
      String enrollId = await createAndApproveEnrollment();
      // enrollment update request
      String command =
          'enroll:update:{"enrollmentId":"$enrollId","namespaces":{"update":"rw"}}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      Response response = Response();
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      // approve enrollment update request
      response = Response();
      command = 'enroll:approve:{"enrollmentId":"$enrollId"}';
      verbParams = getVerbParam(VerbSyntax.enroll, command);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'approved');
      expect(jsonDecode(response.data!)['enrollmentId'], enrollId);
      // verify updated namespace
      String enrollmentKey =
          enrollVerbHandler.getEnrollmentKey(enrollId, currentAtsign: '@alice');
      EnrollDataStoreValue enrollDataStoreValue =
          await enrollVerbHandler.getEnrollDataStoreValue(enrollmentKey);
      expect(enrollDataStoreValue.namespaces['update'], 'rw');
    });
  });

  group('A group of tests related to enroll permissions', () {
    Response response = Response();
    late String enrollmentId;
    setUp(() async {
      await verbTestsSetUp();

      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
    });

    // Key represents the operation and value represents the expected status of
    // enrollment
    var enrollOperationMap = {
      'approve': 'approved',
      'deny': 'denied',
    };

    enrollOperationMap.forEach((operation, expectedStatus) {
      test('A test to verify pending enrollment is $operation', () async {
        // Enroll request
        String enrollmentRequest =
            'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
        HashMap<String, String?> enrollmentRequestVerbParams =
            getVerbParam(VerbSyntax.enroll, enrollmentRequest);
        inboundConnection.getMetaData().isAuthenticated = false;
        EnrollVerbHandler enrollVerbHandler =
            EnrollVerbHandler(secondaryKeyStore);
        await enrollVerbHandler.processVerb(
            response, enrollmentRequestVerbParams, inboundConnection);
        enrollmentId = jsonDecode(response.data!)['enrollmentId'];
        expect(jsonDecode(response.data!)['status'], 'pending');
        String approveEnrollment =
            'enroll:$operation:{"enrollmentId":"$enrollmentId"}';
        HashMap<String, String?> approveEnrollmentVerbParams =
            getVerbParam(VerbSyntax.enroll, approveEnrollment);
        inboundConnection.getMetaData().isAuthenticated = true;
        enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
        await enrollVerbHandler.processVerb(
            response, approveEnrollmentVerbParams, inboundConnection);
        expect(jsonDecode(response.data!)['status'], expectedStatus);
        expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      });
    });
  });

  group(
      'A group of tests to assert enroll operations cannot performed on unauthenticated connection',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify enrollment cannot be approved on an unauthenticated connection',
        () async {
      String enrollmentRequest = 'enroll:approve:{"enrollmentId":"123"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message ==
                  'Cannot approve enrollment without authentication')));
    });

    test(
        'A test to verify enrollment cannot be denied on an unauthenticated connection',
        () async {
      String enrollmentRequest = 'enroll:deny:{"enrollmentId":"123"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message == 'Cannot deny enrollment without authentication')));
    });

    test(
        'A test to verify enrollment cannot be revoked on an unauthenticated connection',
        () async {
      String enrollmentRequest = 'enroll:revoke:{"enrollmentId":"123"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message == 'Cannot revoke enrollment without authentication')));
    });

    test('A test to verify enrollment request without otp throws exception',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appname":"wavi","devicename":"mydevice","namespaces":{"wavi":"r"},"apkampublickey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(isA<IllegalArgumentException>()));
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enroll revoke operations', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify revoke operations thrown exception when given enrollmentId is not in keystore',
        () async {
      String enrollmentId = '123';
      String enrollmentRequest =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = '123';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) => e is AtInvalidEnrollmentException)));
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of hive related test to ensure enrollment keys are not updated in commit log keystore',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to ensure new enrollment key is not added to commit log',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().authType = AuthType.cram;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = '123';
      Response responseObject = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          responseObject, verbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse =
          jsonDecode(responseObject.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      expect(enrollmentResponse['status'], 'approved');
      // Commit log
      Iterator iterator =
          (secondaryKeyStore.commitLog as AtCommitLog).getEntries(-1);
      expect(iterator.moveNext(), false);
    });

    test(
        'A test to ensure new enrollment key on CRAM authenticated connection is not added to commit log',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().authType = AuthType.cram;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = '123';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      expect(enrollmentResponse['status'], 'approved');
      // Commit log
      Iterator iterator =
          (secondaryKeyStore.commitLog as AtCommitLog).getEntries(-1);
      expect(iterator.moveNext(), false);
    });

    test('A test to ensure enroll approval is not added to commit log',
        () async {
      Response response = Response();
      inboundConnection.getMetaData().isAuthenticated = true;
      // GET OTP
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      // Send enrollment request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"buzz":"rw"},"encryptedAPKAMSymmetricKey":"dummy_apkam_symmetric_key","apkamPublicKey":"dummy_apkam_public_key","otp":"${response.data}"}';
      HashMap<String, String?> enrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentVerbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      String enrollmentId = enrollmentResponse['enrollmentId'];
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptedPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encryption_key"}';
      enrollmentVerbParams = getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      await enrollVerbHandler.processVerb(
          response, enrollmentVerbParams, inboundConnection);
      var approveEnrollmentResponse = jsonDecode(response.data!);
      expect(approveEnrollmentResponse['enrollmentId'], enrollmentId);
      expect(approveEnrollmentResponse['status'], 'approved');
      // Verify Commit log does not contain keys with __manage namespace
      Iterator iterator =
          (secondaryKeyStore.commitLog as AtCommitLog).getEntries(-1);
      iterator.moveNext();
      expect(iterator.current.key,
          'public:wavi.mydevice.pkam.__pkams.__public_keys@alice');
      expect(iterator.moveNext(), false);
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enrollment request expiry', () {
    String? otp;
    setUp(() async {
      await verbTestsSetUp();
      // Fetch TOTP
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      inboundConnection.getMetaData().isAuthenticated = true;
      Response defaultResponse = Response();
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
    });

    test('A test to verify expired enrollment cannot be approved', () async {
      Response response = Response();
      // Enroll a request on an unauthenticated connection which will expire in 1 millisecond
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 1;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      await Future.delayed(Duration(milliseconds: 1));
      //Approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) => e is AtInvalidEnrollmentException)));
    });

    test('A test to verify expired enrollment cannot be denied', () async {
      Response response = Response();
      // Enroll a request on an unauthenticated connection which will expire in 1 millisecond
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 1;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id1';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      //Deny enrollment
      await Future.delayed(Duration(milliseconds: 1));
      String approveEnrollmentCommand =
          'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) => e is AtInvalidEnrollmentException)));
    });

    test('A test to verify TTL on approved enrollment is reset', () async {
      Response response = Response();
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 600000;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      String enrollmentKey =
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      // Verify TTL is added to the enrollment
      AtData? enrollmentData = await secondaryKeyStore.get(enrollmentKey);
      expect(enrollmentData!.metaData!.expiresAt, isNotNull);
      expect(enrollmentData.metaData!.ttl, 600000);
      //Approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      // Verify TTL is reset
      enrollmentData = await secondaryKeyStore.get(enrollmentKey);
      expect(enrollmentData!.metaData!.expiresAt, null);
      expect(enrollmentData.metaData!.ttl, 0);
    });

    test(
        'A test to verify TTL is not set for enrollment requested on an authenticated connection',
        () async {
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().authType = AuthType.cram;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(enrollmentId, isNotNull);
      expect(jsonDecode(response.data!)['status'], 'approved');
      // Verify TTL is not set
      AtData? enrollmentData = await secondaryKeyStore.get(
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice');
      expect(enrollmentData!.metaData!.expiresAt, null);
      expect(enrollmentData.metaData!.ttl, null);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to approve enrollment', () {
    String? otp;
    late String enrollmentId;
    late EnrollVerbHandler enrollVerbHandler;
    HashMap<String, String?> enrollVerbParams;
    Response defaultResponse = Response();

    setUp(() async {
      await verbTestsSetUp();
      // Fetch OTP
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      inboundConnection.getMetaData().isAuthenticated = true;
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 60000;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          defaultResponse, enrollVerbParams, inboundConnection);
      enrollmentId = jsonDecode(defaultResponse.data!)['enrollmentId'];
      String status = jsonDecode(defaultResponse.data!)['status'];
      expect(status, 'pending');
    });

    test('A test to verify denied enrollment cannot be approved', () async {
      Response response = Response();
      //deny enrollment
      String denyEnrollmentCommand =
          'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'denied');
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0030');
      expect(response.errorMessage,
          'Enrollment_id: $enrollmentId is denied. Only pending enrollments can be approved');
    });

    test('A test to verify revoked enrollment cannot be approved', () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String denyEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0030');
      // Approved a revoked enrollment throws AtEnrollmentException
      expect(response.errorMessage,
          'Enrollment_id: $enrollmentId is revoked. Only pending enrollments can be approved');
    });

    test('A test to verify pending enrollment cannot be revoked', () async {
      Response response = Response();
      //revoke enrollment
      String denyEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0030');
      expect(response.errorMessage,
          'Enrollment_id: $enrollmentId is pending. Only approved enrollments can be revoked');
    });
  });

  group('validate internal methods of enroll verb handler', () {
    late EnrollVerbHandler enrollVerbHandler;

    setUpAll(() async {
      await verbTestsSetUp();
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
    });

    test('verify behaviour of method: getEnrollmentKey()', () {
      String enrollmentKey = enrollVerbHandler.getEnrollmentKey('123abc');
      expect(enrollmentKey, '123abc.new.enrollments.__manage');
      enrollmentKey =
          enrollVerbHandler.getEnrollmentKey('234bcd', currentAtsign: '@alice');
      expect(enrollmentKey, '234bcd.new.enrollments.__manage@alice');

      String supplementaryEnrollmentKey = enrollVerbHandler
          .getEnrollmentKey('123abc', isSupplementaryKey: true);
      expect(supplementaryEnrollmentKey,
          '123abc.supplementary.enrollments.__manage');
      supplementaryEnrollmentKey = enrollVerbHandler.getEnrollmentKey('234bcd',
          isSupplementaryKey: true, currentAtsign: '@bob');
      expect(supplementaryEnrollmentKey,
          '234bcd.supplementary.enrollments.__manage@bob');
    });

    test('verify behaviour of method: updateEnrollmentValueAndResetTTL()',
        () async {
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'sesssion123', 'unit_test', 'test_device', 'apkaaaaam');
      enrollDataStoreValue.approval = EnrollApproval(EnrollStatus.pending.name);
      enrollDataStoreValue.namespaces = {'test_namespace': 'rw'};
      String enrollmentKey =
          enrollVerbHandler.getEnrollmentKey('1234', currentAtsign: '@alice');
      await enrollVerbHandler.updateEnrollmentValueAndResetTTL(
          enrollmentKey, enrollDataStoreValue);

      AtData? enrollmentKeyStoreValue =
          await secondaryKeyStore.get(enrollmentKey);
      EnrollDataStoreValue enrollValue = EnrollDataStoreValue.fromJson(
          jsonDecode(enrollmentKeyStoreValue!.data!));
      expect(enrollmentKeyStoreValue.metaData!.ttl, 0);
      expect(enrollmentKeyStoreValue.metaData!.expiresAt, null);
      expect(enrollValue.approval!.state, EnrollStatus.pending.name);
      expect(enrollValue.namespaces, {'test_namespace': 'rw'});
    });

    test('verify positive behaviour of method: fetchUpdatedNamespaces',
        () async {
      String enrollId = 'enroll1234';
      String atsign = '@alice';
      String enrollmentKey = enrollVerbHandler.getEnrollmentKey(enrollId,
          currentAtsign: atsign, isSupplementaryKey: true);
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'sesssion123', 'unit_test', 'test_device', 'apkaaaaam');
      enrollDataStoreValue.approval = EnrollApproval(EnrollStatus.pending.name);
      enrollDataStoreValue.namespaces = {'test_namespace': 'rw'};
      // insert a supplementary key into the keystore
      await enrollVerbHandler.updateEnrollmentValueAndResetTTL(
          enrollmentKey, enrollDataStoreValue);
      // validate fetchUpdatedNamespaces
      var updatedNamespaces =
          await enrollVerbHandler.fetchUpdatedNamespaces(enrollId, atsign);
      expect(updatedNamespaces, {'test_namespace': 'rw'});
    });

    test('verify negative behaviour of method: fetchUpdatedNamespaces()',
        () async {
      //invalid enrollment id
      String enrollId = 'enroll6789';
      String atsign = '@alice';
      // ensure invalid enrollmentId throws AtInvalidEnrollmentException
      expect(
          () async =>
              await enrollVerbHandler.fetchUpdatedNamespaces(enrollId, atsign),
          throwsA(predicate((dynamic e) => e is AtInvalidEnrollmentException)));
    });

    test(
        'verify behaviour of method: checkEnrollmentOperationParams() - case AtThrottleLimitExceededException',
        () {
      inboundConnection = CustomInboundConnection(isValid: false);
      EnrollParams enrollParams = EnrollParams()..otp = 'abcd';
      expect(
          () => enrollVerbHandler.checkEnrollmentOperationParams(
              enrollParams.toJson(), inboundConnection, 'request'),
          throwsA(isA<AtThrottleLimitExceeded>()));
      inboundConnection = CustomInboundConnection(isValid: true);
    });

    test(
        'verify behaviour of method: checkEnrollmentOperationParams() - update wihthout apkam authentication',
        () {
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().authType = AuthType.pkamLegacy;
      EnrollParams enrollParams = EnrollParams()..namespaces = {"abdc": "rw"};
      try {
        enrollVerbHandler.checkEnrollmentOperationParams(
            enrollParams.toJson(), inboundConnection, 'update');
      } on Exception catch (e) {
        assert(e is UnAuthenticatedException);
        expect(e.toString(),
            'Exception: Apkam authentication required to update enrollment');
      }

      inboundConnection.getMetaData().isAuthenticated = false;
    });

    test(
        'verify behaviour of method: checkEnrollmentOperationParams() - approve on un-authenticated connection',
        () async {
      inboundConnection.getMetaData().isAuthenticated = false;
      EnrollParams enrollParams = EnrollParams()..namespaces = {"abdc": "rw"};
      expect(
          () => enrollVerbHandler.checkEnrollmentOperationParams(
              enrollParams.toJson(), inboundConnection, 'approve'),
          throwsA(isA<UnAuthenticatedException>()));
    });

    test(
        'verify behaviour of method: checkEnrollmentOperationParams() - revoke with no enrollParams',
        () async {
      inboundConnection.getMetaData().isAuthenticated = true;
      expect(
          () => enrollVerbHandler.checkEnrollmentOperationParams(
              null, inboundConnection, 'revoke'),
          throwsA(isA<IllegalArgumentException>()));
      inboundConnection.getMetaData().isAuthenticated = false;
    });

    test(
        'verify behaviour of method: checkEnrollmentOperationParams() - request with null namespace',
        () async {
      inboundConnection.getMetaData().isAuthenticated = false;
      EnrollParams enrollParams = EnrollParams()..namespaces = null;
      expect(
          () => enrollVerbHandler.checkEnrollmentOperationParams(
              enrollParams.toJson(), inboundConnection, 'request'),
          throwsA(isA<IllegalArgumentException>()));
    });

    test(
        'verify behaviour of method: checkEnrollmentOperationParams() - approve with null enrollId',
        () async {
      inboundConnection.getMetaData().isAuthenticated = true;
      EnrollParams enrollParams = EnrollParams()..namespaces = {"abdc": "rw"};
      expect(
          () => enrollVerbHandler.checkEnrollmentOperationParams(
              enrollParams.toJson(), inboundConnection, 'approve'),
          throwsA(isA<IllegalArgumentException>()));
      inboundConnection.getMetaData().isAuthenticated = false;
    });

    test(
        'verify behaviour of method: processNewEnrollmentRequest() - OTP is invalid',
        () async {
      inboundConnection.getMetaData().isAuthenticated = false;
      String otp = 'WRONGP';
      EnrollParams enrollParams = EnrollParams()
        ..namespaces = {"abdc": "rw"}
        ..otp = otp;
      expect(
          enrollVerbHandler.processNewEnrollmentRequest(
              enrollParams.toJson(), '@atsign123', inboundConnection),
          throwsA(isA<IllegalArgumentException>()));
    });

    test(
        'verify behaviour of method: handleNewEnrollmentRequest() - OTP is null',
        () async {
      EnrollParams enrollParams = EnrollParams()
        ..namespaces = {"abdc": "rw"}
        ..otp = null;
      expect(
          enrollVerbHandler.processNewEnrollmentRequest(
              enrollParams.toJson(), '@atsign123', inboundConnection),
          throwsA(isA<IllegalArgumentException>()));
    });

    test('verify behaviour: handleNewEnrollmentRequest() - valid OTP',
        () async {
      String atsign = '@froyo';
      inboundConnection.getMetaData().sessionID = 'sessssioooon';
      String otp = 'ABCDEF';
      // set otp in the otpVerbHandler cache to mimic otp generation
      await OtpVerbHandler.cache.set(otp, otp);

      EnrollParams enrollParams = EnrollParams()
        ..namespaces = {"abdc": "rw"}
        ..otp = otp
        ..deviceName = 'unit_tester'
        ..appName = 'unit_test_app'
        ..apkamPublicKey = 'apkaaaaaaam';

      EnrollVerbResponse enrollVerbResponse =
          await enrollVerbHandler.processNewEnrollmentRequest(
              enrollParams.toJson(), atsign, inboundConnection);
      assert(enrollVerbResponse.data.containsKey('enrollmentId'));
      expect(enrollVerbResponse.data['status'], 'pending');
    });

    test(
        'verify behaviour: handleEnrollmentUpdateRequest() - update approved enrollment',
        () async {
      inboundConnection.getMetaData().sessionID = 'session123131';
      String atsign = '@frodo';
      String enrollId = 'enroll__7456719';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session2342', 'unit_test', 'test_device', 'apkaaaaam--publiiiic//?');
      enrollDataStoreValue.namespaces = {"unit_test82": "rw"};
      enrollDataStoreValue.approval = EnrollApproval('approved');
      String enrollmentKey =
          enrollVerbHandler.getEnrollmentKey(enrollId, currentAtsign: atsign);
      // update key into the keystore
      await enrollVerbHandler.updateEnrollmentValueAndResetTTL(
          enrollmentKey, enrollDataStoreValue);

      EnrollParams enrollParams = EnrollParams();
      enrollParams.enrollmentId = enrollId;
      enrollParams.namespaces = {'dummy_namespace': 'rw'};
      EnrollVerbResponse enrollVerbResponse =
          await enrollVerbHandler.processUpdateEnrollmentRequest(
              enrollParams.toJson(), atsign, inboundConnection);
      expect(enrollVerbResponse.data['enrollmentId'], enrollId);
      expect(enrollVerbResponse.data['status'], 'pending');
    });

    test(
        'verify behaviour: handleEnrollmentUpdateRequest() - update pending enrollment',
        () async {
      inboundConnection.getMetaData().sessionID = 'session123131';
      String atsign = '@frodo';
      String enrollId = 'enroll__745671982';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session2342', 'unit_test', 'test_device', 'apkaaaaam--publiiiic//?');
      enrollDataStoreValue.namespaces = {"unit_test82": "rw"};
      enrollDataStoreValue.approval = EnrollApproval('pending');
      String enrollmentKey =
          enrollVerbHandler.getEnrollmentKey(enrollId, currentAtsign: atsign);
      // update key into the keystore
      await enrollVerbHandler.updateEnrollmentValueAndResetTTL(
          enrollmentKey, enrollDataStoreValue);

      EnrollParams enrollParams = EnrollParams();
      enrollParams.enrollmentId = enrollId;
      enrollParams.namespaces = {'dummy_namespace': 'rw'};
      EnrollVerbResponse enrollVerbResponse =
          await enrollVerbHandler.processUpdateEnrollmentRequest(
              enrollParams.toJson(), atsign, inboundConnection);
      expect(enrollVerbResponse.response.isError, true);
      expect(enrollVerbResponse.response.errorCode, 'AT0030');
      expect(enrollVerbResponse.response.errorMessage,
          'Enrollment_id: enroll__745671982 is pending. Only approved enrollments can be updated');
    });

    test(
        'verify behaviour: handleEnrollmentUpdateRequest() - update invalid enrollment',
        () async {
      inboundConnection.getMetaData().sessionID = 'session123131';
      String atsign = '@frodo';
      String enrollId = 'invalid_enrollment_id';

      EnrollParams enrollParams = EnrollParams();
      enrollParams.enrollmentId = enrollId;
      enrollParams.namespaces = {'dummy_namespace': 'rw'};
      expect(
          () async => await enrollVerbHandler.processUpdateEnrollmentRequest(
              enrollParams.toJson(), atsign, inboundConnection),
          throwsA(isA<AtInvalidEnrollmentException>()));
    });
  });
}
