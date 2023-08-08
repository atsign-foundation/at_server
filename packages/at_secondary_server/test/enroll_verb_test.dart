import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/response/default_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/response_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/totp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

String scanResponse = '';

class MockResponseHandlerManager extends Mock
    implements ResponseHandlerManager {
  @override
  ResponseHandler getResponseHandler(Verb verb) {
    return MockResponseHandler();
  }
}

class MockResponseHandler extends Mock implements DefaultResponseHandler {
  // Assigning the response the global variable 'scanResponse'.
  @override
  Future<void> process(AtConnection connection, Response response) async {
    scanResponse = getResponseMessage(response.data, '@');
  }

  @override
  String getResponseMessage(String? verbResult, String promptKey) {
    return verbResult!;
  }
}

void main() {
  group('A group of tests to verify enroll request operation', () {
    late ScanVerbHandler scanVerbHandler;
    late ResponseHandlerManager mockResponseHandlerManager;

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
      // TOTP Verb
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.totp, 'totp:get');
      TotpVerbHandler totpVerbHandler = TotpVerbHandler(secondaryKeyStore);
      await totpVerbHandler.processVerb(
          response, totpVerbParams, inboundConnection);
      print('TOTP: ${response.data}');
      // Enroll request 2
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"buzz":"r"},"totp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
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
        'A test to verify scan returns the enrollment keys for an enrolled request',
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
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      scanVerbHandler = ScanVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();
      inboundConnection.getMetaData().isAuthenticated = true;
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan __manage', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(
          scanResponseList
              .contains('$enrollmentId.new.enrollments.__manage@alice'),
          true);
    });

    test(
        'A test to verify scan does not return the enrollment keys for an second connection',
        () async {
      Response response = Response();
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'session_1';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      var enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'name': 'wavi', 'access': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      // TOTP Verb
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.totp, 'totp:get');
      TotpVerbHandler totpVerbHandler = TotpVerbHandler(secondaryKeyStore);
      await totpVerbHandler.processVerb(
          response, totpVerbParams, inboundConnection);
      //  Second connection
      await inboundConnection.close();
      inboundConnection = DummyInboundConnection();
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.metadata.sessionID = 'session_2';

      // Enroll request 2
      enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'name': 'wavi', 'access': 'rw'},
        "totp": "${response.data}",
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      scanVerbHandler = ScanVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();

      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan __manage', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList.contains(keyName), false);
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

    test('A test to verify enrollment list with enrollApprovalId is populated',
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
      // TOTP Verb
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.totp, 'totp:get');
      TotpVerbHandler totpVerbHandler = TotpVerbHandler(secondaryKeyStore);
      await totpVerbHandler.processVerb(
          response, totpVerbParams, inboundConnection);
      print('TOTP: ${response.data}');
      // Enroll request
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"totp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      //Approve enrollment
      String approveEnrollmentRequest =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentRequest);
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

    test('A test to verify enrollment request without totp throws exception',
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
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message == 'invalid totp. Cannot process enroll request')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enrollment authorization', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify delete verb is not allowed when enrollment is not authorized for write operations',
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
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = enrollmentId;
      String deleteCommand = 'delete:dummykey.wavi$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      expect(
          () async => await deleteVerbHandler.processVerb(
              response, deleteVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Enrollment Id: $enrollmentId is not authorized for delete operation on the key: dummykey.wavi@alice')));
    });

    test(
        'A test to verify update verb is not allowed when enrollment is not authorized for write operations',
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
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = enrollmentId;

      String updateCommand = 'update:$alice:dummykey.wavi$alice dummyValue';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      expect(
          () async => await updateVerbHandler.processVerb(
              response, updateVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Enrollment Id: $enrollmentId is not authorized for update operation on the key: @alice:dummykey.wavi@alice')));
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
      String enrollmentRequest = 'enroll:revoke:{"enrollmentId":"123"}';
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
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message == 'enrollment id: 123 not found in keystore')));
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
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      expect(enrollmentResponse['status'], 'success');
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
      expect(enrollmentResponse['status'], 'success');
      // Commit log
      Iterator iterator =
          (secondaryKeyStore.commitLog as AtCommitLog).getEntries(-1);
      expect(iterator.moveNext(), false);
    });

    test('A test to ensure enroll approval is not added to commit log',
        () async {
      Response response = Response();
      inboundConnection.getMetaData().isAuthenticated = true;
      // GET TOTP
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.totp, 'totp:get');
      TotpVerbHandler totpVerbHandler = TotpVerbHandler(secondaryKeyStore);
      await totpVerbHandler.processVerb(
          response, totpVerbParams, inboundConnection);
      // Send enrollment request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"buzz":"rw"},"encryptedAPKAMSymmetricKey":"dummy_apkam_symmetric_key","apkamPublicKey":"dummy_apkam_public_key","totp":"${response.data}"}';
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
      // Approve enrollment
      String approveEnrollmentRequest =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptedPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encryption_key"}';
      enrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentRequest);
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
}
