import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
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

    test('A test to verify OTP is deleted once it is used to submit an enrollment',() async {
      Response response = Response();
      // OTP Verb
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
      getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String otp = response.data!;

      String enrollmentRequest =
      'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"buzz":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(enrollmentId, isNotNull);
      expect(await enrollVerbHandler.isOTPValid(otp), false);
    });
    tearDown(() async => await verbTestsTearDown());
  });
  group('A group of tests to verify enroll list operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enrollment list', () async {
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

      String enrollmentList = 'enroll:list';
      verbParams = getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.data?.contains(enrollmentId), true);
    });

    test('A test to verify enrollment list with enrollmentId is populated',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
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
      expect(response.data?.contains(enrollmentId), true);
    });

    test(
        'A test to verify enrollment list without __manage namespace returns enrollment info of given enrollmentId',
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
      String enrollmentIdOne = jsonDecode(response.data!)['enrollmentId'];
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      print('OTP: ${response.data}');
      // Enroll request
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.getMetaData().isAuthenticated = true;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      // Enroll list
      String enrollmentList = 'enroll:list';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = enrollmentId;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollListResponse = jsonDecode(response.data!);
      var responseTest = enrollListResponse[
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'];
      print(responseTest);
      expect(responseTest['appName'], 'wavi');
      expect(responseTest['deviceName'], 'mydevice');
      expect(responseTest['namespace']['wavi'], 'r');
      expect(
          enrollListResponse.containsKey(
              '$enrollmentIdOne.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'),
          false);
    });

    tearDown(() async => await verbTestsTearDown());
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
      String enrollmentRequest = 'enroll:approve:enrollmentid:123';
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
      String enrollmentRequest = 'enroll:deny:enrollmentid:123';
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
      String enrollmentRequest = 'enroll:revoke:enrollmentid:123';
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
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
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
              e is AtEnrollmentException &&
              e.message == 'invalid otp. Cannot process enroll request')));
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
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorMessage, isNotNull);
      assert(response.errorMessage!
          .contains('enrollment_id: $enrollmentId is expired'));
      expect(response.errorCode, 'AT0028');
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
      Map<String, dynamic> enrollmentResponse = jsonDecode(responseObject.data!);
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
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorMessage, isNotNull);
      assert(response.errorMessage!
          .contains('enrollment_id: $enrollmentId is expired'));
      expect(response.errorCode, 'AT0028');
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
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorMessage, isNotNull);
      assert(response.errorMessage!
          .contains('enrollment_id: $enrollmentId is expired'));
      expect(response.errorCode, 'AT0028');
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
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Cannot approve a denied enrollment. Only pending enrollments can be approved')));
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
      // Approved a revoked enrollment throws AtEnrollmentException
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, approveEnrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Cannot approve a revoked enrollment. Only pending enrollments can be approved')));
    });

    test('A test to verify pending enrollment cannot be revoked', () async {
      Response response = Response();
      //revoke enrollment
      String denyEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Cannot revoke a pending enrollment. Only approved enrollments can be revoked')));
    });
  });
}
