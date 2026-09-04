import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  setUp(() async {
    await verbTestsSetUp();
    atServer.inboundConnectionManager =
        InboundConnectionManager(serverAtSign: alice, poolSize: 3);
  });

  group(
      'A group tests to verify monitor verb when connection is authenticate using legacy PKAM',
      () {
    test('A test to verify monitor verb writes all notifications', () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
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
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
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
          MonitorVerbHandler(keyValueStore, notificationManager);
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
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
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
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify publicKeyHash is written on InboundConnection when populated',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AtConstants.regex] = 'wavi';
      inboundConnection.metaData.isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
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
            ..messageType = MessageType.key
            ..atMetaData = (AtMetaData()
              ..pubKeyHash =
                  PublicKeyHash('dummy_hash', HashingAlgoType.sha512.name)))
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['metadata']['pubKeyHash'],
          '{"hash":"dummy_hash","hashingAlgo":"sha512"}');
    });

    test(
        'A test to verify publicKeyHash is set to null on InboundConnection when not populated',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AtConstants.regex] = 'wavi';
      inboundConnection.metaData.isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
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
            ..messageType = MessageType.key
            ..atMetaData = (AtMetaData()
              ..encKeyName = 'encKeyName'
              ..sharedKeyEnc = 'shared_key_encrypted'))
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['metadata']['pubKeyHash'], null);
      expect(notificationMap['metadata']['encKeyName'], 'encKeyName');
      expect(
          notificationMap['metadata']['sharedKeyEnc'], 'shared_key_encrypted');
    });
    tearDown(() async {
      await verbTestsTearDown();
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
      inboundConnection.metaData.enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r"}));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.buzz@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      expect(inboundConnection.lastWrittenData, isNull);

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.wavi@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], '$alice:phone.wavi@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify notifications matching multiple namespaces in enrollment are pushed',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r", "buzz": 'rw'}));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.buzz@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], '$alice:phone.buzz@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.wavi@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], '$alice:phone.wavi@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify only notification matching the regex is pushed when multiple namespaces are given in enrollment',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AtConstants.regex] = 'wavi';
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r", "buzz": "rw"}));

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.buzz@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      expect(inboundConnection.lastWrittenData, isNull);

      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.wavi@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], '$alice:phone.wavi@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    test(
        'A test to verify enrollment with * and __manage namespace receives notifications of all namespaces',
        () async {
      Response response = Response();
      HashMap<String, String?> monitorVerbParams = HashMap<String, String?>();
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"rw"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      inboundConnection.metaData.enrollmentId =
          jsonDecode(response.data!)['enrollmentId'];
      expect(jsonDecode(response.data!)['status'], 'approved');

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), monitorVerbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.wavi@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], '$alice:phone.wavi@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.buzz@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], '$alice:phone.buzz@bob');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
    });

    Future<String> newEnrollment(
        String appName, String deviceName, Map<String, String> namespaces,
        {required bool autoApprove}) async {
      OtpVerbHandler otpVH = OtpVerbHandler(keyValueStore);
      String otp = otpVH.generateOTP();
      await otpVH.savePasscode(otp, ttl: 5000, isSpp: false);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      String enrollmentRequest = 'enroll:request:'
          '{"otp":"$otp"'
          ',"appName":"$appName"'
          ',"deviceName":"$deviceName"'
          ',"namespaces":${jsonEncode(namespaces)}'
          ',"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"'
          ',"encryptedAPKAMSymmetricKey":"dummy_encrypted_apkam_symmetric_key"'
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
      var mvp = VerbUtil.getVerbParam(
        VerbSyntax.monitor,
        'monitor:selfNotifications',
      )!;

      DummyInboundConnection pkamMC = DummyInboundConnection();
      pkamMC.metaData.authType = AuthType.pkamLegacy;
      pkamMC.metaData.isAuthenticated = true;
      pkamMC.metaData.sessionID = 'legacy_pkam_monitor_session';
      await MonitorVerbHandler(keyValueStore, notificationManager)
          .processVerb(Response(), mvp, pkamMC);

      String nextEnrollmentId = await newEnrollment(
        'mvt_app_2',
        'mvt_dev_2',
        {"app_2_namespace": "rw"},
        autoApprove: false,
      );

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
          '$alice');
    });

    test('Test delivery of enrollment request notification to APKAM', () async {
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
      inboundConnection.metaData.enrollmentId = monitorsEnrollmentId;
      inboundConnection.metaData.authType = AuthType.apkam;
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'apkam_monitor_session';
      await MonitorVerbHandler(keyValueStore, notificationManager)
          .processVerb(Response(), mvp, inboundConnection);

      String nextEnrollmentId = await newEnrollment(
        'mvt_app_2',
        'mvt_dev_2',
        {"app_2_namespace": "rw"},
        autoApprove: false,
      );

      await Future.delayed(Duration(milliseconds: 10));
      var notificationJson = jsonDecode(inboundConnection.lastWrittenData!
          .replaceAll('notification:', '')
          .trim());
      expect(notificationJson['value'], isNotNull);
      final valueJson = jsonDecode(notificationJson['value']);
      //TODO remove encryptedApkamSymmetricKey in the future
      expect(valueJson['encryptedApkamSymmetricKey'],
          'dummy_encrypted_apkam_symmetric_key');
      expect(valueJson['encryptedAPKAMSymmetricKey'],
          'dummy_encrypted_apkam_symmetric_key');
      expect(valueJson['appName'], 'mvt_app_2');
      expect(valueJson['deviceName'], 'mvt_dev_2');
      expect(valueJson['namespace'], equals({'app_2_namespace': 'rw'}));
      expect(
          notificationJson['key'],
          '$nextEnrollmentId'
          '.new.enrollments.__manage'
          '$alice');
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
      await enMgr.put(
        enrollmentId,
        AtData()..data = jsonEncode(enrollJson),
        EnrollmentStatus.approved,
      );

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.wavi@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      Map notificationMap = jsonDecode(inboundConnection.lastWrittenData!);

      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], '$alice:phone.wavi@bob');
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
      await enMgr.put(
        enrollmentId,
        AtData()..data = jsonEncode(enrollJson),
        EnrollmentStatus.revoked,
      );
      atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = '$alice:phone.wavi@bob'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();
      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      expect(inboundConnection.lastWrittenData, isEmpty);
    });
    tearDown(() async {
      await verbTestsTearDown();
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
          MonitorVerbHandler(keyValueStore, notificationManager);
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
          MonitorVerbHandler(keyValueStore, notificationManager);
      await expectLater(
          monitorVerbHandler.processVerb(
              Response(), verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'Invalid regex: ${verbParams[AtConstants.regex]}')));
    });

    test(
        'Verify InvalidSyntaxException is thrown on APKAM auth connection when invalid regex is supplied',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      verbParams[AtConstants.regex] = '[';
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId =
          await setEnrollmentKey(jsonEncode({"wavi": "r"}));
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await expectLater(
          monitorVerbHandler.processVerb(
              Response(), verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'Invalid regex: ${verbParams[AtConstants.regex]}')));
    });
    tearDown(() async {
      await verbTestsTearDown();
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
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);

      AtMetaData randomMetadata = createRandomAtMetaData('@bob');
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.self
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..atMetaData = randomMetadata)
          .build();

      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      await Future.delayed(Duration(milliseconds: 10));

      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      expect(notificationMap['metadata']['pubKeyCS'], randomMetadata.pubKeyCS);
      expect(notificationMap['metadata']['sharedKeyEnc'],
          randomMetadata.sharedKeyEnc);
      expect(
          notificationMap['metadata']['encKeyName'], randomMetadata.encKeyName);
      expect(notificationMap['metadata']['dataSignature'],
          randomMetadata.dataSignature);
      expect(notificationMap['metadata']['pubKeyHash'],
          jsonEncode(randomMetadata.pubKeyHash?.toJson()));
    });

    test(
        'A test to verify received notification is written to monitor connection invoking callback method',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);

      AtMetaData randomMetadata = createRandomAtMetaData('@bob');
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..atMetaData = randomMetadata)
          .build();

      await monitorVerbHandler.processAtNotification(
          inboundConnection, atNotification);
      await Future.delayed(Duration(milliseconds: 10));

      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      expect(notificationMap['metadata']['pubKeyCS'], randomMetadata.pubKeyCS);
      expect(notificationMap['metadata']['sharedKeyEnc'],
          randomMetadata.sharedKeyEnc);
      expect(
          notificationMap['metadata']['encKeyName'], randomMetadata.encKeyName);
      expect(notificationMap['metadata']['dataSignature'],
          randomMetadata.dataSignature);
      expect(notificationMap['metadata']['pubKeyHash'],
          jsonEncode(randomMetadata.pubKeyHash?.toJson()));
    });

    test(
        'A test to verify sent notification is not written to monitor connection',
        () async {
      HashMap<String, String?> verbParams = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = true;
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);

      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = alice
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'sent_should_not_be_received_on_monitor.wavi'
            ..type = NotificationType.sent
            ..opType = OperationType.update
            ..messageType = MessageType.key)
          .build();

      await notificationManager.notify(atNotification);
      Completer sent = Completer();
      when(() => mockOutboundConnection.write(any(
              that: contains('sent_should_not_be_received_on_monitor.wavi'))))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:success\n@".codeUnits);
        if (!sent.isCompleted) {
          sent.complete();
        }
      });
      await sent.future;
      expect(inboundConnection.lastWrittenData, null);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });
  });

  group('A test to verify initial notifications list has all metadata', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify self notification is written to monitor connection in initial list',
        () async {
      int epoch = DateTime.timestamp().millisecondsSinceEpoch;
      await Future.delayed(Duration(milliseconds: 1));
      AtMetaData randomMetadata = createRandomAtMetaData('@bob');
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.self
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..atMetaData = randomMetadata)
          .build();
      await notificationManager.put(atNotification.id, atNotification);

      String monitorCommand = 'monitor:selfNotifications:$epoch';

      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      HashMap<String, String?> verbParams =
          monitorVerbHandler.parse(monitorCommand);
      inboundConnection.metaData.isAuthenticated = true;
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);

      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      expect(notificationMap['metadata']['pubKeyCS'], randomMetadata.pubKeyCS);
      expect(notificationMap['metadata']['sharedKeyEnc'],
          randomMetadata.sharedKeyEnc);
      expect(
          notificationMap['metadata']['encKeyName'], randomMetadata.encKeyName);
      expect(notificationMap['metadata']['dataSignature'],
          randomMetadata.dataSignature);
      expect(notificationMap['metadata']['pubKeyHash'],
          jsonEncode(randomMetadata.pubKeyHash?.toJson()));
    });

    test(
        'A test to verify received notification is written to monitor connection in initial list',
        () async {
      int epoch = DateTime.timestamp().millisecondsSinceEpoch;
      await Future.delayed(Duration(milliseconds: 1));

      AtMetaData randomMetadata = createRandomAtMetaData('@bob');
      var atNotification = (AtNotificationBuilder()
            ..id = 'abc'
            ..fromAtSign = '@bob'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = alice
            ..notification = 'phone.wavi'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..atMetaData = randomMetadata)
          .build();
      await notificationManager.put(atNotification.id, atNotification);

      String monitorCommand = 'monitor:$epoch';
      MonitorVerbHandler monitorVerbHandler =
          MonitorVerbHandler(keyValueStore, notificationManager);
      HashMap<String, String?> verbParams =
          monitorVerbHandler.parse(monitorCommand);
      inboundConnection.metaData.isAuthenticated = true;
      await monitorVerbHandler.processVerb(
          Response(), verbParams, inboundConnection);

      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData
          ?.replaceAll('notification:', '')
          .trim();
      var notificationMap = jsonDecode(inboundConnection.lastWrittenData!);
      expect(notificationMap['id'], 'abc');
      expect(notificationMap['from'], '@bob');
      expect(notificationMap['to'], alice);
      expect(notificationMap['key'], 'phone.wavi');
      expect(notificationMap['messageType'], 'MessageType.key');
      expect(notificationMap['operation'], 'update');
      expect(notificationMap['metadata']['pubKeyCS'], randomMetadata.pubKeyCS);
      expect(notificationMap['metadata']['sharedKeyEnc'],
          randomMetadata.sharedKeyEnc);
      expect(
          notificationMap['metadata']['encKeyName'], randomMetadata.encKeyName);
      expect(notificationMap['metadata']['dataSignature'],
          randomMetadata.dataSignature);
      expect(notificationMap['metadata']['pubKeyHash'],
          jsonEncode(randomMetadata.pubKeyHash?.toJson()));
    });

    tearDown(() async {
      await verbTestsTearDown();
    });
  });
}

Future<String> setEnrollmentKey(String namespace) async {
  Response response = Response();
  EnrollVerbHandler enrollVerbHandler =
      EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
  inboundConnection.metaData.isAuthenticated = true;
  inboundConnection.metaData.sessionID = 'dummy_session';
  HashMap<String, String?> totpVerbParams =
      getVerbParam(VerbSyntax.otp, 'otp:get');
  OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
  await otpVerbHandler.processVerb(response, totpVerbParams, inboundConnection);
  String enrollmentRequest =
      'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":$namespace,"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
  HashMap<String, String?> enrollmentRequestVerbParams =
      getVerbParam(VerbSyntax.enroll, enrollmentRequest);
  inboundConnection.metaData.isAuthenticated = false;
  enrollVerbHandler =
      EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
  await enrollVerbHandler.processVerb(
      response, enrollmentRequestVerbParams, inboundConnection);
  String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
  String approveEnrollmentRequest =
      'enroll:approve:{"enrollmentId":"$enrollmentId", "encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
  HashMap<String, String?> approveEnrollmentVerbParams =
      getVerbParam(VerbSyntax.enroll, approveEnrollmentRequest);
  inboundConnection.metaData.isAuthenticated = true;
  enrollVerbHandler =
      EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
  await enrollVerbHandler.processVerb(
      response, approveEnrollmentVerbParams, inboundConnection);
  return enrollmentId;
}
