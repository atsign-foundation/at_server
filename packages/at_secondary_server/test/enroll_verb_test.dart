import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

InboundConnectionMetadata castMetadata(InboundConnection ic) {
  return inboundConnection.metaData as InboundConnectionMetadata;
}

void main() {
  group('A group of tests to verify enroll request operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enroll requests get different enrollment ids',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
          'enroll:request:{"appName":"wavi1","deviceName":"mydevice1"'
          ',"namespaces":{"buzz":"r"},"otp":"${response.data}"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
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
          'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"wavi":"r"}'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
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

    test(
        'A test to verify OTP is deleted once it is used to submit an enrollment',
        () async {
      Response response = Response();
      // OTP Verb
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String otp = response.data!;

      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"buzz":"r"},"otp":"$otp"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey": "ipsum_apkam"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(enrollmentId, isNotNull);
      expect(await enrollVerbHandler.isPasscodeValid(otp), false);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests to verify enroll list operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enrollment list with cram auth', () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey":"dummy_encrypted_apkam_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
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
      var responseMap = jsonDecode(response.data!);
      expect(response.data?.contains(enrollmentId), true);
      expect(
          responseMap['$enrollmentId.new.enrollments.__manage@alice']
              ['appName'],
          'wavi');
      expect(
          responseMap['$enrollmentId.new.enrollments.__manage@alice']
              ['deviceName'],
          'mydevice');
      expect(
          responseMap['$enrollmentId.new.enrollments.__manage@alice']
              ['namespace']['wavi'],
          'r');
    });

    test('A test to verify enrollment list with enrollmentId is populated',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentList = 'enroll:list';
      castMetadata(inboundConnection).enrollmentId = enrollmentId;
      verbParams = getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.data?.contains(enrollmentId), true);
    });

    test(
        'A test to verify enrollment list without __manage namespace returns enrollment info of given enrollmentId',
        () async {
      Response response = Response();
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
          'enroll:request:{"appName":"buzz","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey":"default_apkam_symmetric_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.metaData.isAuthenticated = true;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      // Enroll list
      String enrollmentList = 'enroll:list';
      castMetadata(inboundConnection).enrollmentId = enrollmentId;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollListResponse = jsonDecode(response.data!);
      var responseTest = enrollListResponse[
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'];
      print(responseTest);
      expect(responseTest['appName'], 'buzz');
      expect(responseTest['deviceName'], 'mydevice');
      expect(responseTest['namespace']['wavi'], 'r');
      expect(responseTest['encryptedAPKAMSymmetricKey'],
          'default_apkam_symmetric_key');
      expect(
          enrollListResponse.containsKey(
              '$enrollmentIdOne.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'),
          false);
    });

    test('fetch filtered enrollment requests using approval status', () async {
      // test conditions set-up
      EnrollVerbHandler enrollVerb = EnrollVerbHandler(secondaryKeyStore);
      inboundConnection.metadata.isAuthenticated = true;
      EnrollDataStoreValue enrollValue = EnrollDataStoreValue('abcd',
          'unit_test_enroll', 'testDevice', 'apkaaaaaamPublicKeyyyyy././')
        ..namespaces = {"unit_tst": "rw"}
        ..encryptedAPKAMSymmetricKey = 'encSyMeTrIcKey././';
      // Distribution of enrollments below:
      // Approved = 1(key: 0); Pending = 2(keys: 1,2); Revoked = 3(keys: 3,4,5); Denied = 4(keys: 6,7,8,9);
      // (This distribution will be used for validation)
      List<String> approvalStatuses = [
        EnrollmentStatus.approved.name,
        EnrollmentStatus.pending.name,
        EnrollmentStatus.pending.name,
        EnrollmentStatus.revoked.name,
        EnrollmentStatus.revoked.name,
        EnrollmentStatus.revoked.name,
        EnrollmentStatus.denied.name,
        EnrollmentStatus.denied.name,
        EnrollmentStatus.denied.name,
        EnrollmentStatus.denied.name,
      ];

      // will be used to store newly created enrollment keys
      List<String> enrollmentKeys = [];
      Map<String, EnrollDataStoreValue> enrollmentData = {};
      // create 10 random enrollments and store them into keystore
      for (int i = 0; i < 10; i++) {
        String enrollmentId = Uuid().v4();
        String enrollmentKey =
            '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
        enrollValue.approval = EnrollApproval(approvalStatuses[i]);
        enrollmentData[enrollmentKey] = enrollValue;

        enrollmentKeys.add(enrollmentKey);
        await secondaryKeyStore.put(
            enrollmentKey, AtData()..data = jsonEncode(enrollValue));
      }

      String enrollmentStatus = 'approved';
      String command =
          'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response approvedResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      Map<String, dynamic> fetchedEnrollments =
          jsonDecode(approvedResponse.data!);
      expect(fetchedEnrollments.length, 1);
      assert(approvedResponse.data!.contains(enrollmentKeys[0]));

      enrollmentStatus = 'pending';
      command = 'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response pendingResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(pendingResponse.data!);
      expect(fetchedEnrollments.length, 2);
      assert(pendingResponse.data!.contains(enrollmentKeys[1]));
      assert(pendingResponse.data!.contains(enrollmentKeys[2]));

      enrollmentStatus = 'revoked';
      command = 'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response revokedResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(revokedResponse.data!);
      expect(fetchedEnrollments.length, 3);
      assert(revokedResponse.data!.contains(enrollmentKeys[3]));
      assert(revokedResponse.data!.contains(enrollmentKeys[4]));
      assert(revokedResponse.data!.contains(enrollmentKeys[5]));

      enrollmentStatus = 'denied';
      command = 'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response deniedResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(deniedResponse.data!);
      expect(fetchedEnrollments.length, 4);
      assert(deniedResponse.data!.contains(enrollmentKeys[6]));
      assert(deniedResponse.data!.contains(enrollmentKeys[7]));
      assert(deniedResponse.data!.contains(enrollmentKeys[8]));
      assert(deniedResponse.data!.contains(enrollmentKeys[9]));

      command = 'enroll:list'; // run enroll list without filter
      Response listAllResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(listAllResponse.data!);
      expect(fetchedEnrollments.length, 10);
    });

    test('enroll list with an invalid approvalStateFilter', () async {
      EnrollVerbHandler enrollVerb = EnrollVerbHandler(secondaryKeyStore);
      inboundConnection.metadata.isAuthenticated = true;

      String approvalStatus = 'invalid_status';
      String command =
          'enroll:list:{"enrollmentStatusFilter":["$approvalStatus"]}';
      expect(
          () async =>
              await enrollVerb.processInternal(command, inboundConnection),
          throwsA(predicate((e) => e is ArgumentError)));
    });

    test(
        'verify verb params being populated with correct enrollmentStatusFilter',
        () {
      inboundConnection.metadata.isAuthenticated = true;

      String approvalStatus = 'approved';
      String command =
          'enroll:list:{"enrollmentStatusFilter":["$approvalStatus"]}';
      Map<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      var enrollParams = jsonDecode(verbParams['enrollParams']!);
      expect(enrollParams['enrollmentStatusFilter'], [approvalStatus]);
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enroll permissions', () {
    Response response = Response();
    late String enrollmentId;
    setUp(() async {
      await verbTestsSetUp();

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
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
            'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
            ',"namespaces":{"wavi":"r"},"otp":"${response.data}"'
            ',"apkamPublicKey":"dummy_apkam_public_key"'
            ',"encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
        HashMap<String, String?> enrollmentRequestVerbParams =
            getVerbParam(VerbSyntax.enroll, enrollmentRequest);
        inboundConnection.metaData.isAuthenticated = false;
        EnrollVerbHandler enrollVerbHandler =
            EnrollVerbHandler(secondaryKeyStore);
        await enrollVerbHandler.processVerb(
            response, enrollmentRequestVerbParams, inboundConnection);
        enrollmentId = jsonDecode(response.data!)['enrollmentId'];
        expect(jsonDecode(response.data!)['status'], 'pending');
        String approveEnrollment =
            'enroll:$operation:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
        HashMap<String, String?> approveEnrollmentVerbParams =
            getVerbParam(VerbSyntax.enroll, approveEnrollment);
        inboundConnection.metaData.isAuthenticated = true;
        enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
        await enrollVerbHandler.processVerb(
            response, approveEnrollmentVerbParams, inboundConnection);
        expect(jsonDecode(response.data!)['status'], expectedStatus);
        expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      });
    });
    tearDown(() async => await verbTestsTearDown());
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
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
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
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
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
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
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
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
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
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      castMetadata(inboundConnection).enrollmentId =
          '456'; // a client cannot revoke its own enrollment. Set a different enrollmentId in inbound
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
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      castMetadata(inboundConnection).enrollmentId = '123';
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
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      castMetadata(inboundConnection).enrollmentId = '123';
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
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentVerbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      String enrollmentId = enrollmentResponse['enrollmentId'];
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encryption_key"}';
      enrollmentVerbParams = getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
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
      inboundConnection.metaData.isAuthenticated = true;
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
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key", "encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      await Future.delayed(Duration(milliseconds: 500));
      //Approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
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
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id1';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      //Deny enrollment
      await Future.delayed(Duration(milliseconds: 500));
      String denyEnrollmentCommand =
          'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
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
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
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
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
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
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
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
    String enrollmentIdWithManageNamespace = Uuid().v4();
    String? otp;
    late String enrollmentId;
    late EnrollVerbHandler enrollVerbHandler;
    HashMap<String, String?> enrollVerbParams;
    Response defaultResponse = Response();
    setUp(() async {
      await verbTestsSetUp();
      // Store an enrollment request which has access to "__manage" namespace to approve enrollment requests.
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'manage-session-id',
          'buzz',
          'my-phone',
          'manage-enrollment-public-key')
        ..namespaces = {'__manage': 'rw', 'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await secondaryKeyStore.put(
          '$enrollmentIdWithManageNamespace.$newEnrollmentKeyPattern.$enrollManageNamespace$alice',
          AtData()..data = jsonEncode(enrollDataStoreValue.toJson()));
      // Fetch OTP
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      inboundConnection.metaData.isAuthenticated = true;
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 60000;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
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
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'denied');
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Failed to approve enrollment id: $enrollmentId. Cannot approve a denied enrollment. Only pending enrollments can be approved')));
    });

    test('A test to verify revoke enrollment', () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
    });

    test('A test to verify revoke enrollment with force flag', () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:force:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
    });

    test(
        'A test to verify revoke enrollment throws exception when a client is trying to revoke own enrollment without force flag',
        () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      inboundConnection.metadata.enrollmentId = enrollmentIdWithManageNamespace;

      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentIdWithManageNamespace"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message == 'Current client cannot revoke its own enrollment')));
    });

    test(
        'A test to verify enrollment is revoked when a client is trying to revoke own enrollment with force flag',
        () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      inboundConnection.metadata.enrollmentId = enrollmentIdWithManageNamespace;

      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:force:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
    });

    test('A test to verify revoked enrollment cannot be approved', () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
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
                  'Failed to approve enrollment id: $enrollmentId. Cannot approve a revoked enrollment. Only pending enrollments can be approved')));
    });

    test('A test to verify pending enrollment cannot be revoked', () async {
      Response response = Response();
      //revoke enrollment
      String denyEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Failed to revoke enrollment id: $enrollmentId. Cannot revoke a pending enrollment. Only approved enrollments can be revoked')));
    });
  });

  group('A group of tests related enrollment unrevoke operation', () {
    String enrollmentIdWithManageNamespace = Uuid().v4();
    String? otp;
    late String enrollmentId;
    late EnrollVerbHandler enrollVerbHandler;
    HashMap<String, String?> enrollVerbParams;
    Response defaultResponse = Response();
    setUp(() async {
      await verbTestsSetUp();
      // Store an enrollment request which has access to "__manage" namespace to approve enrollment requests.
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'manage-session-id',
          'buzz',
          'my-phone',
          'manage-enrollment-public-key')
        ..namespaces = {'__manage': 'rw', 'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await secondaryKeyStore.put(
          '$enrollmentIdWithManageNamespace.$newEnrollmentKeyPattern.$enrollManageNamespace$alice',
          AtData()..data = jsonEncode(enrollDataStoreValue.toJson()));
      // Fetch OTP
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      inboundConnection.metaData.isAuthenticated = true;
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 60000;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          defaultResponse, enrollVerbParams, inboundConnection);
      enrollmentId = jsonDecode(defaultResponse.data!)['enrollmentId'];
      String status = jsonDecode(defaultResponse.data!)['status'];
      expect(status, 'pending');
    });

    test(
        'A test to verify unrevoke enrollment sets the enrollment state to approved',
        () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      // un- revoke enrollment
      String unrevokeEnrollmentCommand =
          'enroll:unrevoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, unrevokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
    });

    test(
        'A test to verify unrevoke enrollment throws exception when enrollment state is not revoked',
        () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      // un- revoke enrollment
      String unrevokeEnrollmentCommand =
          'enroll:unrevoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, unrevokeEnrollmentCommand);

      await expectLater(
          () => enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Failed to unrevoke enrollment id: $enrollmentId. Cannot un-revoke a approved enrollment. Only revoked enrollments can be un-revoked')));
    });

    test(
        'A test to verify unrevoke enrollment throws exception when enrollmentId is not supplied',
        () async {
      Response response = Response();
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      // un- revoke enrollment
      String unrevokeEnrollmentCommand = 'enroll:unrevoke:{"enrollmentId":""}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, unrevokeEnrollmentCommand);
      expect(
          () => enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message == 'enrollmentId is mandatory for enroll:unrevoke')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of test to verify getDelayIntervalInSeconds method', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'A test to verify getDelayIntervalInSeconds return delay in increment order',
        () {
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);

      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 1000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 2000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 3000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 5000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 8000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 13000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 21000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 34000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 55000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 55000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 55000);
    });

    test(
        'A test to verify getDelayIntervalInSeconds is reset only after threshold is met',
        () async {
      EnrollVerbHandler.initialDelayInMilliseconds = 100;
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.delayForInvalidOTPSeries = [
        0,
        EnrollVerbHandler.initialDelayInMilliseconds
      ];
      enrollVerbHandler.enrollmentResponseDelayIntervalInMillis = 500;
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      // First Invalid request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"123","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      try {
        await enrollVerbHandler.processVerb(
            response, enrollVerbParams, inboundConnection);
        // Do nothing on exception
      } on AtEnrollmentException catch (_) {}
      expect(enrollVerbHandler.getEnrollmentResponseDelayInMilliseconds(), 100);
      // Second Invalid request and verify the delay response interval is incremented.
      enrollmentRequest =
          'enroll:request:{"appName":"buzz","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"123","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, enrollmentRequest);

      try {
        await enrollVerbHandler.processVerb(
            response, enrollVerbParams, inboundConnection);
      } on AtEnrollmentException catch (_) {}
      expect(enrollVerbHandler.getEnrollmentResponseDelayInMilliseconds(), 200);
      // Third Invalid request and verify the delay response interval is incremented.
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"another_device"'
          ',"namespaces":{"wavi":"r"},"otp":"123"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      try {
        await enrollVerbHandler.processVerb(
            response, enrollVerbParams, inboundConnection);
      } on AtEnrollmentException catch (_) {}
      expect(enrollVerbHandler.getEnrollmentResponseDelayInMilliseconds(), 300);

      // Get OTP and send a valid enrollment request. Verify the delay response is
      // not reset because the threshold is not met.
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      inboundConnection.metaData.isAuthenticated = true;
      await otpVerbHandler.processVerb(
          response, getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection);

      inboundConnection.metaData.isAuthenticated = false;
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"third_device"'
          ',"namespaces":{"wavi":"r"},"otp":"${response.data}"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['status'], 'pending');
      // When threshold limit is not met, assert the delay interval is not reset.
      expect(enrollVerbHandler.getEnrollmentResponseDelayInMilliseconds(), 300);
      // Wait for 5 seconds to for threshold to met to reset the delay in response.
      await Future.delayed(Duration(milliseconds: 500));
      // Get OTP and send a valid Enrollment request
      inboundConnection.metaData.isAuthenticated = true;
      await otpVerbHandler.processVerb(
          response, getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection);
      inboundConnection.metaData.isAuthenticated = false;
      enrollmentRequest =
          'enroll:request:{"appName":"buzz","deviceName":"second_device"'
          ',"namespaces":{"wavi":"r"},"otp":"${response.data}"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['status'], 'pending');
      // When threshold limit is met, assert the delay interval is reset.
      expect(enrollVerbHandler.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to validating the enrollment request', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify same app and same device name throws exception when enrollment is approved',
        () async {
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      String key = '123.new.enrollments.__manage$alice';
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue('123', 'wavi', 'iphone', 'dummy_public_key');
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.approved.name);

      AtData atData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await secondaryKeyStore.put(key, atData);

      EnrollParams enrollParams = EnrollParams()
        ..appName = 'wavi'
        ..deviceName = 'iphone'
        ..apkamPublicKey = 'dummy_public_key'
        ..namespaces = {'wavi': 'rw'};

      expect(
          () async =>
              await enrollVerbHandler.validateEnrollmentRequest(enrollParams),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Another enrollment with id 123 exists with the app name: ${enrollParams.appName} and device name: ${enrollParams.deviceName} in approved state')));
    });

    test(
        'A test to verify same app and same device name throws exception when enrollment is pending',
        () async {
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      String key = '123.new.enrollments.__manage$alice';
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue('123', 'wavi', 'iphone', 'dummy_public_key');
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.pending.name);

      AtData atData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await secondaryKeyStore.put(key, atData);

      EnrollParams enrollParams = EnrollParams()
        ..appName = 'wavi'
        ..deviceName = 'iphone'
        ..apkamPublicKey = 'dummy_public_key'
        ..namespaces = {'wavi': 'rw'};

      expect(
          () async =>
              await enrollVerbHandler.validateEnrollmentRequest(enrollParams),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Another enrollment with id 123 exists with the app name: ${enrollParams.appName} and device name: ${enrollParams.deviceName} in pending state')));
    });

    test(
        'A test to verify enrollment requests with same appName and different deviceName is submitted successfully',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // First enrollment request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-1","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      // Second enrollment request
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-2","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_2 = jsonDecode(response.data!)['enrollmentId'];

      expect(enrollmentId_1, isNotEmpty);
      expect(enrollmentId_2, isNotEmpty);
      expect(enrollmentId_1 == enrollmentId_2, false);
    });

    test(
        'A test to verify enrollment requests with different appName and same deviceName is submitted successfully',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // First enrollment request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-1","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      // Second enrollment request
      enrollmentRequest =
          'enroll:request:{"appName":"buzz","deviceName":"device-1","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_2 = jsonDecode(response.data!)['enrollmentId'];

      expect(enrollmentId_1, isNotEmpty);
      expect(enrollmentId_2, isNotEmpty);
      expect(enrollmentId_1 == enrollmentId_2, false);
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enroll:fetch', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enroll:fetch returns the enrollment data', () async {
      // Insert the enrollment data
      String key = '123.new.enrollments.__manage$alice';
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue('123', 'wavi', 'iphone', 'dummy_public_key');
      enrollDataStoreValue.namespaces = {'wavi': 'rw'};
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.approved.name);
      enrollDataStoreValue.encryptedAPKAMSymmetricKey = 'dummy_apkam_key';
      AtData atData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await secondaryKeyStore.put(key, atData);

      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);

      String enrollmentRequest = 'enroll:fetch:{"enrollmentId":"123"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      Map enrollmentResponse = jsonDecode(response.data!);

      expect(enrollmentResponse['appName'], enrollDataStoreValue.appName);
      expect(enrollmentResponse['deviceName'], enrollDataStoreValue.deviceName);
      expect(enrollmentResponse['namespace'], enrollDataStoreValue.namespaces);
      expect(
          enrollmentResponse['status'], enrollDataStoreValue.approval?.state);
      expect(enrollmentResponse['encryptedAPKAMSymmetricKey'],
          enrollDataStoreValue.encryptedAPKAMSymmetricKey);
    });

    tearDown(() async => await verbTestsTearDown());
  });
  group('A group of tests related to validate mandatory params in enrollment',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to validate appName is mandatory for enroll:request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message == 'appName is mandatory for enroll:request')));
    });
    test('A test to validate deviceName is mandatory for enroll:request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message == 'deviceName is mandatory for enroll:request')));
    });
    test('A test to validate apkam public key is mandatory for enroll:request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice", "namespaces":{"wavi":"r"}}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'apkam public key is mandatory for enroll:request')));
    });
    test(
        'A test to validate encrypted apkam symmetric key is mandatory for new client enrollment',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi1","deviceName":"mydevice1","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'encrypted apkam symmetric key is mandatory for new client enroll:request')));
    });
    test('A test to validate namespace is mandatory for new client enrollment',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi1","deviceName":"mydevice1","namespaces":{},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'At least one namespace must be specified for new client enroll:request')));
    });
    test('A test to validate enrollmentId is mandatory for enroll:approve',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:approve:{"encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message == 'enrollmentId is mandatory for enroll:approve')));
    });
    test(
        'A test to validate encryptedDefaultEncryptionPrivateKey is mandatory for enroll:approve',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:approve:{"enrollmentId":"abc123", "encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'encryptedDefaultEncryptionPrivateKey is mandatory for enroll:approve')));
    });
    test(
        'A test to validate encryptedDefaultSelfEncryptionKey is mandatory for enroll:approve',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:approve:{"enrollmentId":"abc123","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'encryptedDefaultSelfEncryptionKey is mandatory for enroll:approve')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of tests to verify client authorization to approve the enrollment request',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify that the authorization check throws exception when the client is not authorized to __manage namespace',
        () async {
      String key = '123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await secondaryKeyStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      inboundConnection.metaData.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';

      expect(
          () async => await enrollVerbHandler.isAuthorized(
              inboundConnection.metadata,
              namespace: 'data.my_app',
              enrolledNamespaceAccess: 'rw',
              operation: 'approve'),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'The approving enrollment does not have access to "__manage" namespace')));
    });

    test(
        'A test to verify that the authorization check returns true when the client is PKAM authentication and enrollment id is null',
        () async {
      String key = '123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {allNamespaces: 'rw'};
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await secondaryKeyStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      inboundConnection.metaData.isAuthenticated = true;

      var res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);
    });

    test('A test to verify namespace hierarchies on enrolling side', () async {
      String key = '123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'my_app': 'rw', '__manage': 'rw', 'buzz': 'r'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await secondaryKeyStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      inboundConnection.metaData.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';

      var res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'orders.data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'buzz', enrolledNamespaceAccess: 'rw');
      expect(res, false);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'buzz', enrolledNamespaceAccess: 'r');
      expect(res, true);
    });

    test('A test to verify namespace hierarchies on approving side', () async {
      String key = '123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'data.my_app': 'rw', '__manage': 'rw', 'buzz': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await secondaryKeyStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      inboundConnection.metaData.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';

      var res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'orders.data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'other.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, false);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'fizzbuzz');
      expect(res, false);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'fizz.buzz', enrolledNamespaceAccess: 'rw');
      expect(res, true);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of tests to ensure enrollment keys are only access by certain verbs',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify update verb cannot update the enrollment key',
        () async {
      String key = '123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'my_app': 'rw', '__manage': 'rw', 'buzz': 'r'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await secondaryKeyStore.put(key, atData);
      inboundConnection.metadata.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';

      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);

      expect(
          () async => await updateVerbHandler.process(
              'update:123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice 1234',
              inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID 123 is not authorized to update key: 123.new.enrollments.__manage@alice')));
    });

    test(
        'A test to verify delete verb cannot delete the enrollment key (using delete verb)',
        () async {
      String key = '123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'my_app': 'rw', '__manage': 'rw', 'buzz': 'r'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await secondaryKeyStore.put(key, atData);
      inboundConnection.metadata.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';

      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);

      expect(
          () async => await deleteVerbHandler.process(
              'delete:123.$newEnrollmentKeyPattern.$enrollManageNamespace$alice',
              inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID 123 is not authorized to delete key: 123.new.enrollments.__manage@alice')));
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('Group of tests to validate enroll delete operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('Validate behaviour of deleting denied enrollment', () async {
      String dummyEnrollId = '2134567809009';
      String enrollmentKey =
          '$dummyEnrollId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId', 'dummy-app', 'dummy-device', 'dummmy-key')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.denied.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await secondaryKeyStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';
      EnrollVerbHandler enrollVerb = EnrollVerbHandler(secondaryKeyStore);

      Response verbResponse = await enrollVerb.processInternal(
          enrollDeleteCommand, inboundConnection);
      expect(verbResponse.data,
          '{"enrollmentId":"$dummyEnrollId","status":"deleted"}');
    });

    test('Validate behaviour of deleting revoked enrollment', () async {
      String dummyEnrollId = '34534253436';
      String enrollmentKey =
          '$dummyEnrollId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId', 'dummy-app', 'dummy-device', 'dummmy-key')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.revoked.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await secondaryKeyStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';
      EnrollVerbHandler enrollVerb = EnrollVerbHandler(secondaryKeyStore);

      Response verbResponse = await enrollVerb.processInternal(
          enrollDeleteCommand, inboundConnection);
      expect(verbResponse.data,
          '{"enrollmentId":"$dummyEnrollId","status":"deleted"}');
    });

    test(
        'Validate negative behaviour of deleting denied enrollment from unAuthenticated connection',
        () async {
      String dummyEnrollId = '39458346583465';
      String enrollmentKey =
          '$dummyEnrollId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId-1', 'dummy-app-1', 'dummy-device-1', 'dummmy-key-1')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.denied.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await secondaryKeyStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = false;
      castMetadata(inboundConnection).enrollmentId = '123653';
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';
      EnrollVerbHandler enrollVerb = EnrollVerbHandler(secondaryKeyStore);

      expect(
          () => enrollVerb.processInternal(
              enrollDeleteCommand, inboundConnection),
          throwsA(predicate((e) =>
              e.toString() ==
              'Exception: Cannot delete enrollment without authentication')));
    });

    test(
        'Validate negative behaviour of deleting revoked enrollment from unAuthenticated connection',
        () async {
      String dummyEnrollId = '4750345034850983';
      String enrollmentKey =
          '$dummyEnrollId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId-11', 'dummy-app-11', 'dummy-device-11', 'dummmy-key-11')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.revoked.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await secondaryKeyStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = false;
      castMetadata(inboundConnection).enrollmentId = '1425365';
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';
      EnrollVerbHandler enrollVerb = EnrollVerbHandler(secondaryKeyStore);

      expect(
          () => enrollVerb.processInternal(
              enrollDeleteCommand, inboundConnection),
          throwsA(predicate((e) =>
              e.toString() ==
              'Exception: Cannot delete enrollment without authentication')));
    });

    test('Validate negative behaviour of deleting approved enrollment',
        () async {
      String dummyEnrollId = '345345345141';
      String enrollmentKey =
          '$dummyEnrollId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId-2', 'dummy-app-2', 'dummy-device-2', 'dummmy-key-2')
        ..namespaces = {'test_namespace-2': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await secondaryKeyStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123653';
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';

      EnrollVerbHandler enrollVerb = EnrollVerbHandler(secondaryKeyStore);
      expect(
          () => enrollVerb.processInternal(
              enrollDeleteCommand, inboundConnection),
          throwsA(predicate((e) =>
              e.toString() ==
              'Exception: Failed to delete enrollment id: 345345345141 | Cause: Cannot delete approved enrollments. Only denied enrollments can be deleted')));
    });

    tearDown(() async => await verbTestsTearDown());
  });
}
