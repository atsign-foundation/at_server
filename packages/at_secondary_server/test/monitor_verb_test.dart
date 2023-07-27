import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/totp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  group(
      'A group tests to verify monitor verb when connection is authenticate using legacy PKAM',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to verify monitor verb writes all notifications', () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.getMetaData().isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);

      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify monitor verb writes only notifications that matches regex',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AT_REGEX] = 'wavi';
      inboundConnection.getMetaData().isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);

      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.buzz'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      expect(inboundConnection.lastWrittenData, isNull);

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of tests to verify monitor verb when connection is authenticated using APKAM',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify only notification matching the namespace in enrollment is pushed',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AT_REGEX] = 'wavi';
      inboundConnection.getMetaData().isAuthenticated = true;
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = await setEnrollmentKey(jsonEncode({"wavi": "r"}));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.buzz'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      expect(inboundConnection.lastWrittenData, isNull);

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify notifications matching multiple namespaces in enrollment are pushed',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.getMetaData().isAuthenticated = true;
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
              .enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r", "buzz": 'rw'}));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.buzz'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.buzz');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify only notification matching the regex is pushed when multiple namespaces are given in enrollment',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AT_REGEX] = 'wavi';
      inboundConnection.getMetaData().isAuthenticated = true;
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
              .enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r", "buzz": "rw"}));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.buzz'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      expect(inboundConnection.lastWrittenData, isNull);

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify enrollment with * and __manage namespace receives notifications of all namespaces',
        () async {
      Response response = Response();
      HashMap<String, String?> monitorVerbParams = HashMap<String, String?>();
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"rw"},"apkamPublicKey":"dummy_apkam_public_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.getMetaData().authType = AuthType.cram;
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session_id';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(jsonDecode(response.data!)['status'], 'approved');

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), monitorVerbParams, inboundConnection);
      // Notification with wavi namespace
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      // Notification with buzz namespace
      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.buzz'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.buzz');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test('A test to verify enrollment revoked does not receive notifications',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metadata.isAuthenticated = true;
      var enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      var enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], '@alice');
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      // Set to empty string to remove the previous data
      inboundConnection.lastWrittenData = '';
      enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'revoked'}
      };
      keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      expect(inboundConnection.lastWrittenData, isEmpty);
    });
  });

  group('A group of tests to verify exceptions thrown by monitor verb', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'Verify unauthenticated exception is thrown when connection is not authenticated',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.getMetaData().isAuthenticated = false;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      expect(
          () async => await monitorVerbHandler.processVerb(
              Response(), verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message ==
                  'Failed to execute verb. monitor requires authentication')));
    });

    test(
        'verify InvalidSyntaxException is thrown on PKAM auth connection when invalid regex is supplied',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AT_REGEX] = '[';
      inboundConnection.getMetaData().isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();

      expect(
          () async =>
              await monitorVerbHandler.processAtNotification(atNotification),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Invalid regular expression. ${verbParams[AT_REGEX]} is not a valid regex')));
    });

    test(
        'Verify InvalidSyntaxException is thrown on APKAM auth connection when invalid regex is supplied',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AT_REGEX] = '[';
      inboundConnection.getMetaData().isAuthenticated = true;
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = await setEnrollmentKey(jsonEncode({"wavi": "r"}));
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();

      expect(
          () async =>
              await monitorVerbHandler.processAtNotification(atNotification),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Invalid regular expression. ${verbParams[AT_REGEX]} is not a valid regex')));
    });
  });
}

Future<String> setEnrollmentKey(String namespace) async {
  Response response = Response();
  EnrollVerbHandler enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
  inboundConnection.getMetaData().isAuthenticated = true;
  inboundConnection.getMetaData().sessionID = 'dummy_session';
  // TOTP Verb
  HashMap<String, String?> totpVerbParams =
      getVerbParam(VerbSyntax.totp, 'totp:get');
  TotpVerbHandler totpVerbHandler = TotpVerbHandler(secondaryKeyStore);
  await totpVerbHandler.processVerb(
      response, totpVerbParams, inboundConnection);
  // Enroll request
  String enrollmentRequest =
      'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":$namespace,"totp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
  HashMap<String, String?> enrollmentRequestVerbParams =
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
  return enrollmentId;
}
