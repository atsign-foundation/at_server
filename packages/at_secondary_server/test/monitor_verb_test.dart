import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/expect.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  setUpAll(() {
    InboundConnectionPool.getInstance().init(3, isColdInit: true);
  });
  group(
      'A group tests to verify monitor verb when connection is authenticate using legacy PKAM',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to verify monitor verb writes all notifications', () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
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
      verbParams[AtConstants.regex] = 'wavi';
      inboundConnection.metaData.isAuthenticated = true;
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
    tearDown(() async {
      await verbTestsTearDown();
      AtNotificationCallback.getInstance().callbackMethods.clear();
    });
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
      verbParams[AtConstants.regex] = 'wavi';
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r"}));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '@alice:phone.buzz@bob'
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
            ..notification = '@alice:phone.wavi@bob'
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
      expect(notificationMap['key'], '@alice:phone.wavi@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify notifications matching multiple namespaces in enrollment are pushed',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
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
            ..notification = '@alice:phone.buzz@bob'
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
      expect(notificationMap['key'], '@alice:phone.buzz@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '@alice:phone.wavi@bob'
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
      expect(notificationMap['key'], '@alice:phone.wavi@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify only notification matching the regex is pushed when multiple namespaces are given in enrollment',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AtConstants.regex] = 'wavi';
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
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
            ..notification = '@alice:phone.buzz@bob'
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
            ..notification = '@alice:phone.wavi@bob'
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
      expect(notificationMap['key'], '@alice:phone.wavi@bob');
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
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          jsonDecode(response.data!)['enrollmentId'];
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
            ..notification = '@alice:phone.wavi@bob'
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
      expect(notificationMap['key'], '@alice:phone.wavi@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      // Notification with buzz namespace
      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '@alice:phone.buzz@bob'
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
      expect(notificationMap['key'], '@alice:phone.buzz@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    Future<String> newEnrollment(
        String appName, String deviceName, Map<String, String> namespaces,
        {required bool autoApprove}) async {
      OtpVerbHandler otpVH = OtpVerbHandler(secondaryKeyStore);
      String otp = otpVH.generateOTP();
      await otpVH.saveOTP(otp, 5000);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(secondaryKeyStore);
      String enrollmentRequest = 'enroll:request:'
          '{"otp":"$otp"'
          ',"appName":"$appName"'
          ',"deviceName":"$deviceName"'
          ',"namespaces":${jsonEncode(namespaces)}'
          ',"apkamPublicKey":"dummy_apkam_public_key"'
          ',"encryptedAPKAMSymmetricKey":"dummy_encrypted_apkam_symm_key"'
          '}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      DummyInboundConnection enrollRequestConnection = DummyInboundConnection();
      if (autoApprove) {
        enrollRequestConnection.metaData.isAuthenticated = true;
        enrollRequestConnection.metaData.authType = AuthType.cram;
      } else {
        enrollRequestConnection.metaData.isAuthenticated = false;
      }
      enrollRequestConnection.metaData.sessionID = 'enroll_session';
      Response response = Response();
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, enrollRequestConnection);

      if (autoApprove) {
        expect(jsonDecode(response.data!)['status'], 'approved');
      } else {
        expect(jsonDecode(response.data!)['status'], 'pending');
      }

      return jsonDecode(response.data!)['enrollmentId']!;
    }

    test('Test delivery of enrollment request notification to PKAM', () async {
      // - Make an inboundConnection without enrollmentId (i.e. legacy PKAM)
      //   and issue monitor command with selfNotifications flag set
      // - Make an enrollment request on another connection
      // - Verify that the monitor connection receives the
      //   enrollment request notification

      var mvp = VerbUtil.getVerbParam(
        VerbSyntax.monitor,
        'monitor:selfNotifications',
      )!;

      // Make an inboundConnection without enrollmentId (i.e. legacy PKAM)
      //    and issue monitor command with selfNotifications flag set
      DummyInboundConnection pkamMC = DummyInboundConnection();
      pkamMC.metaData.authType = AuthType.pkamLegacy;
      pkamMC.metaData.isAuthenticated = true;
      pkamMC.metaData.sessionID = 'legacy_pkam_monitor_session';
      await MonitorVerbHandler(secondaryKeyStore)
          .processVerb(Response(), mvp, pkamMC);

      // Make another enrollment request
      String nextEnrollmentId = await newEnrollment(
        'mvt_app_2',
        'mvt_dev_2',
        {"app_2_namespace": "rw"},
        autoApprove: false,
      );

      // Verify that the monitor connection receives the
      //    enrollment request notification
      var notificationJson = jsonDecode(
          pkamMC.lastWrittenData!.replaceAll('notification:', '').trim());
      expect(notificationJson['value'], isNotNull);
      final valueJson = jsonDecode(notificationJson['value']);
      expect(valueJson['appName'], 'mvt_app_2');
      expect(valueJson['deviceName'], 'mvt_dev_2');
      expect(valueJson['namespace'], equals({'app_2_namespace': 'rw'}));
      expect(
          notificationJson['key'],
          '$nextEnrollmentId'
          '.new.enrollments.__manage'
          '@alice');
      print('Verified the legacy PKAM monitor connection'
          ' received the enrollment request notification');
    });

    test('Test delivery of enrollment request notification to APKAM', () async {
      // - Make an enrollment with * and __manage permissions
      // - Make an inboundConnection with that enrollment ID and
      //   issue monitor command with selfNotifications flag set
      // - Make an enrollment request on another connection
      // - Verify that the APKAM monitor connection receives the
      //    enrollment request notification

      // Make an enrollment with * and __manage permissions
      String monitorsEnrollmentId = await newEnrollment(
        'mvt_app_1',
        'mvt_dev_1',
        {"*": "rw", "__manage": "rw"},
        autoApprove: true,
      );

      var mvp = VerbUtil.getVerbParam(
        VerbSyntax.monitor,
        'monitor:selfNotifications',
      )!;
      // Make an inboundConnection with that enrollment ID and
      //    issue monitor command with selfNotifications flag set
      DummyInboundConnection apkamMC = DummyInboundConnection();
      (apkamMC.metaData as InboundConnectionMetadata).enrollmentId =
          monitorsEnrollmentId;
      apkamMC.metaData.authType = AuthType.apkam;
      apkamMC.metaData.isAuthenticated = true;
      apkamMC.metaData.sessionID = 'apkam_monitor_session';
      await MonitorVerbHandler(secondaryKeyStore)
          .processVerb(Response(), mvp, apkamMC);

      // Make another enrollment request
      String nextEnrollmentId = await newEnrollment(
        'mvt_app_2',
        'mvt_dev_2',
        {"app_2_namespace": "rw"},
        autoApprove: false,
      );

      // Verify that the APKAM monitor connection receives the
      //    enrollment request notification
      var notificationJson = jsonDecode(
          apkamMC.lastWrittenData!.replaceAll('notification:', '').trim());
      expect(notificationJson['value'], isNotNull);
      final valueJson = jsonDecode(notificationJson['value']);
      //TODO remove encryptedApkamSymmetricKey in the future
      expect(valueJson['encryptedApkamSymmetricKey'],
          'dummy_encrypted_apkam_symm_key');
      expect(valueJson['encryptedAPKAMSymmetricKey'],
          'dummy_encrypted_apkam_symm_key');
      expect(valueJson['appName'], 'mvt_app_2');
      expect(valueJson['deviceName'], 'mvt_dev_2');
      expect(valueJson['namespace'], equals({'app_2_namespace': 'rw'}));
      expect(
          notificationJson['key'],
          '$nextEnrollmentId'
          '.new.enrollments.__manage'
          '@alice');
      print('Verified the APKAM monitor connection'
          ' received the enrollment request notification');
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
            ..notification = '@alice:phone.wavi@bob'
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
      expect(notificationMap['key'], '@alice:phone.wavi@bob');
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
            ..notification = '@alice:phone.wavi@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(atNotification);
      expect(inboundConnection.lastWrittenData, isEmpty);
    });
    tearDown(() async {
      await verbTestsTearDown();
      AtNotificationCallback.getInstance().callbackMethods.clear();
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
      inboundConnection.metaData.isAuthenticated = false;
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
      verbParams[AtConstants.regex] = '[';
      inboundConnection.metaData.isAuthenticated = true;
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
                  'Invalid regular expression. ${verbParams[AtConstants.regex]} is not a valid regex')));
    });

    test(
        'Verify InvalidSyntaxException is thrown on APKAM auth connection when invalid regex is supplied',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AtConstants.regex] = '[';
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r"}));
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(secondaryKeyStore);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '@alice:phone.wavi@bob'
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
                  'Invalid regular expression. ${verbParams[AtConstants.regex]} is not a valid regex')));
    });
    tearDown(() async {
      await verbTestsTearDown();
      AtNotificationCallback.getInstance().callbackMethods.clear();
    });
  });

  group('A test to verify invocation of callback methods', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify self notification is written to monitor connection invoking callback method',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AtConstants.monitorSelfNotifications] = 'selfNotifications';
      inboundConnection.metaData.isAuthenticated = true;
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
            ..type = NotificationType.self
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      // The notification callback method is registered in "MonitorVerbHandler.processVerb"
      await AtNotificationCallback.getInstance()
          .invokeCallbacks(atNotification);

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
        'A test to verify received notification is written to monitor connection invoking callback method',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
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
      // The notification callback method is registered in "MonitorVerbHandler.processVerb"
      await AtNotificationCallback.getInstance()
          .invokeCallbacks(atNotification);

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
        'A test to verify sent notification is not written to monitor connection',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
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
            ..type = NotificationType.sent
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      // The notification callback method is registered in "MonitorVerbHandler.processVerb"
      await AtNotificationCallback.getInstance()
          .invokeCallbacks(atNotification);
      expect(inboundConnection.lastWrittenData, null);
    });

    tearDown(() async {
      await verbTestsTearDown();
      AtNotificationCallback.getInstance().callbackMethods.clear();
    });
  });
}

Future<String> setEnrollmentKey(String namespace) async {
  Response response = Response();
  EnrollVerbHandler enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
  inboundConnection.metaData.isAuthenticated = true;
  inboundConnection.metaData.sessionID = 'dummy_session';
  // OTP Verb
  HashMap<String, String?> totpVerbParams =
      getVerbParam(VerbSyntax.otp, 'otp:get');
  OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
  await otpVerbHandler.processVerb(response, totpVerbParams, inboundConnection);
  // Enroll request
  String enrollmentRequest =
      'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":$namespace,"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key"}';
  HashMap<String, String?> enrollmentRequestVerbParams =
      getVerbParam(VerbSyntax.enroll, enrollmentRequest);
  inboundConnection.metaData.isAuthenticated = false;
  enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
  await enrollVerbHandler.processVerb(
      response, enrollmentRequestVerbParams, inboundConnection);
  String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
  //Approve enrollment
  String approveEnrollmentRequest =
      'enroll:approve:{"enrollmentId":"$enrollmentId"}';
  HashMap<String, String?> approveEnrollmentVerbParams =
      getVerbParam(VerbSyntax.enroll, approveEnrollmentRequest);
  inboundConnection.metaData.isAuthenticated = true;
  enrollVerbHandler = EnrollVerbHandler(secondaryKeyStore);
  await enrollVerbHandler.processVerb(
      response, approveEnrollmentVerbParams, inboundConnection);
  return enrollmentId;
}
