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
import 'package:at_secondary/src/verb/handler/totp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group(
      'a group of tests to verify enroll data store value - toJson and fromJson',
      () {
    test('enroll approval object fromJson', () {
      final enrollApprovalJson = {'state': 'requested'};
      final enrollApprovalObject = EnrollApproval.fromJson(enrollApprovalJson);
      expect(enrollApprovalObject, isA<EnrollApproval>());
      expect(enrollApprovalObject.state, 'requested');
    });
    test('enroll approval object toJson', () {
      final enrollApproval = EnrollApproval('requested');
      final enrollApprovalJson = enrollApproval.toJson();
      expect(enrollApprovalJson['state'], 'requested');
    });

    test('enroll namespace object fromJson', () {
      final enrollNamespaceJson = {'name': 'buzz', 'access': 'r'};
      final enrollNamespaceObject =
          EnrollNamespace.fromJson(enrollNamespaceJson);
      expect(enrollNamespaceObject, isA<EnrollNamespace>());
      expect(enrollNamespaceObject.name, 'buzz');
      expect(enrollNamespaceObject.access, 'r');
    });

    test('enroll namespace object toJson', () {
      final enrollNamespace = EnrollNamespace('wavi', 'rw');
      final enrollNamespaceJson = enrollNamespace.toJson();
      expect(enrollNamespaceJson['name'], 'wavi');
      expect(enrollNamespaceJson['access'], 'rw');
    });

    test('enroll data store value object toJson', () {
      final enrollNamespace1 = EnrollNamespace('wavi', 'rw');
      final enrollNamespace2 = EnrollNamespace('buzz', 'r');
      final enrollApproval = EnrollApproval('requested');
      final namespaceList = [enrollNamespace1, enrollNamespace2];
      final enrollDataStoreValue =
          EnrollDataStoreValue('123', 'testclient', 'iphone', 'mykey')
            ..namespaces = namespaceList
            ..approval = enrollApproval
            ..requestType = EnrollRequestType.newEnrollment;
      final enrollJson = enrollDataStoreValue.toJson();
      expect(enrollJson['sessionId'], '123');
      expect(enrollJson['appName'], 'testclient');
      expect(enrollJson['deviceName'], 'iphone');
      expect(enrollJson['apkamPublicKey'], 'mykey');
      expect(enrollJson['requestType'], 'newEnrollment');
      expect(enrollJson['namespaces'][0], enrollNamespace1);
      expect(enrollJson['namespaces'][1], enrollNamespace2);
      expect(enrollJson['approval'], enrollApproval);
    });
    test('enroll data store value object fromJson', () {
      final enrollJson = {
        'sessionId': '123',
        'appName': 'testclient',
        'deviceName': 'iphone',
        'namespaces': [
          {'name': 'wavi', 'access': 'rw'},
          {'name': 'buzz', 'access': 'r'}
        ],
        'apkamPublicKey': 'mykey',
        'requestType': 'newEnrollment',
        'approval': {'state': 'requested'}
      };
      final enrollValueObject = EnrollDataStoreValue.fromJson(enrollJson);
      expect(enrollValueObject, isA<EnrollDataStoreValue>());
      expect(enrollValueObject.approval, isA<EnrollApproval>());
      expect(enrollValueObject.namespaces, isA<List<EnrollNamespace>>());
      expect(enrollValueObject.sessionId, '123');
      expect(enrollValueObject.appName, 'testclient');
      expect(enrollValueObject.deviceName, 'iphone');
      expect(enrollValueObject.apkamPublicKey, 'mykey');
      expect(enrollValueObject.requestType, EnrollRequestType.newEnrollment);
    });
  });

  group('A group of tests on enroll list operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enrollment list', () async {
      String enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:apkampublickey:dummy_apkam_public_key';
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
      verbParams = getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.data?.contains(enrollmentId), true);
    });

    test('A test to verify enrollment list with enrollApprovalId is populated',
        () async {
      String enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:apkampublickey:dummy_apkam_public_key';
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
          .enrollApprovalId = enrollmentId;
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
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:apkampublickey:dummy_apkam_public_key';
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

      // Enroll request
      enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:totp:${response.data}:apkampublickey:dummy_apkam_public_key';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      //Approve enrollment
      String approveEnrollmentRequest =
          'enroll:approve:enrollmentId:$enrollmentId';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);

      // Enroll list
      String enrollmentList = 'enroll:list';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollApprovalId = enrollmentId;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollListResponse = jsonDecode(response.data!);
      var responseTest = enrollListResponse[
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice'];
      expect(responseTest['appName'], 'wavi');
      expect(responseTest['deviceName'], 'mydevice');
      expect(responseTest['namespace'][0]['name'], 'wavi');
      expect(responseTest['namespace'][0]['access'], 'r');
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
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:apkampublickey:dummy_apkam_public_key';
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
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:apkampublickey:dummy_apkam_public_key';
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
          .enrollApprovalId = enrollmentId;

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
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:apkampublickey:dummy_apkam_public_key';
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
          .enrollApprovalId = enrollmentId;

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
      String enrollmentRequest = 'enroll:revoke:enrollmentid:123';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollApprovalId = '123';
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

  group('A group of tests related to enrollment request expiry', () {
    Response response = Response();
    setUp(() async {
      await verbTestsSetUp();
      // Fetch TOTP
      String totpCommand = 'totp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.totp, totpCommand);
      TotpVerbHandler totpVerbHandler = TotpVerbHandler(secondaryKeyStore);
      inboundConnection.getMetaData().isAuthenticated = true;
      await totpVerbHandler.processVerb(
          response, totpVerbParams, inboundConnection);
    });
    test('A test to verify expired enrollment cannot be approved', () async {
      // Enroll a request on an unauthenticated connection which will expire in 1 millisecond
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 1;
      String enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:totp:${response.data}:apkampublickey:dummy_apkam_public_key';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      //Approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:enrollmentid:$enrollmentId';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message == 'The enrollment $enrollmentId is expired')));
    });

    test('A test to verify expired enrollment cannot be denied', () async {
      // Enroll a request on an unauthenticated connection which will expire in 1 millisecond
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 1;
      String enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:totp:${response.data}:apkampublickey:dummy_apkam_public_key';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      //Deny enrollment
      String approveEnrollmentCommand =
          'enroll:deny:enrollmentid:$enrollmentId';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message == 'The enrollment $enrollmentId is expired')));
    });

    test('A test to verify TTL on approved enrollment is reset', () async {
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 60000;
      String enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:totp:${response.data}:apkampublickey:dummy_apkam_public_key';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      // Verify TTL is added to the enrollment
      AtData? enrollmentData = await secondaryKeyStore.get(
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice');
      expect(enrollmentData!.metaData!.expiresAt, isNotNull);
      expect(enrollmentData.metaData!.ttl, 60000);
      //Approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:enrollmentid:$enrollmentId';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      // Verify TTL is reset
      enrollmentData = await secondaryKeyStore.get(
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice');
      expect(enrollmentData!.metaData!.expiresAt, null);
      expect(enrollmentData.metaData!.ttl, 0);
    });

    test(
        'A test to verify TTL is not set for enrollment requested on an authenticated connection',
        () async {
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      String enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:totp:${response.data}:apkampublickey:dummy_apkam_public_key';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(enrollmentId, isNotNull);
      expect(jsonDecode(response.data!)['status'], 'success');
      // Verify TTL is not set
      AtData? enrollmentData = await secondaryKeyStore.get(
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice');
      expect(enrollmentData!.metaData!.expiresAt, null);
      expect(enrollmentData.metaData!.ttl, null);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enroll approve operation', () {
    Response response = Response();
    late String enrollmentId;
    late EnrollVerbHandler enrollVerbHandler;
    HashMap<String, String?> enrollVerbParams;
    setUp(() async {
      await verbTestsSetUp();
      // Fetch TOTP
      String totpCommand = 'totp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.totp, totpCommand);
      TotpVerbHandler totpVerbHandler = TotpVerbHandler(secondaryKeyStore);
      inboundConnection.getMetaData().isAuthenticated = true;
      await totpVerbHandler.processVerb(
          response, totpVerbParams, inboundConnection);
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
      enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
      enrollVerbHandler.enrollmentExpiryInMills = 60000;
      String enrollmentRequest =
          'enroll:request:appname:wavi:devicename:mydevice:namespaces:[wavi,r]:totp:${response.data}:apkampublickey:dummy_apkam_public_key';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().isAuthenticated = false;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
    });
    test('A test to verify denied enrollment cannot be approved', () async {
      //deny enrollment
      String denyEnrollmentCommand = 'enroll:deny:enrollmentid:$enrollmentId';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'denied');
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:enrollmentid:$enrollmentId';
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:enrollmentid:$enrollmentId';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String denyEnrollmentCommand = 'enroll:revoke:enrollmentid:$enrollmentId';
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
      //revoke enrollment
      String denyEnrollmentCommand = 'enroll:revoke:enrollmentid:$enrollmentId';
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
