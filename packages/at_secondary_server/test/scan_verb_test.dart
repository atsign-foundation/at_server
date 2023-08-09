import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/response/default_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/response_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

// Global variable to assert the scan responses from the mock response handlers
String scanResponse = '';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {
  @override
  List<String> getKeys({String? regex}) {
    return [
      'public:location.wavi@alice',
      'public:__phone.wavi@alice',
      '_mobile.wavi@alice'
    ];
  }
}

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

class MockOutboundClientManager extends Mock implements OutboundClientManager {}

class MockAtCacheManager extends Mock implements AtCacheManager {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
  AtCacheManager mockAtCacheManager = MockAtCacheManager();

  group('A group of scan verb tests', () {
    test('test scan getVerb', () {
      var handler = ScanVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var verb = handler.getVerb();
      expect(verb is Scan, true);
    });

    test('test scan command accept test', () {
      var command = 'scan';
      var handler = ScanVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test scan key- invalid keyword', () {
      var verb = Scan();
      var command = 'scaan';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test scan verb - upper case', () {
      var command = 'SCAN';
      command = SecondaryUtil.convertCommand(command);
      var handler = ScanVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test scan verb - space in between', () {
      var verb = Scan();
      var command = 'sc an';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test scan verb - invalid syntax', () {
      var command = 'scann';
      var inbound = InboundConnectionImpl(null, null);
      var defaultVerbExecutor = DefaultVerbExecutor();
      var defaultVerbHandlerManager = DefaultVerbHandlerManager(
          mockKeyStore,
          mockOutboundClientManager,
          mockAtCacheManager,
          StatsNotificationService.getInstance(),
          NotificationManager.getInstance());

      expect(
          () => defaultVerbExecutor.execute(
              command, inbound, defaultVerbHandlerManager),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test scan verb with forAtSign and regular expression', () {
      var verb = Scan();
      var command = 'scan:@bob ^@kevin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[FOR_AT_SIGN], '@bob');
      expect(paramsMap[AT_REGEX], '^@kevin');
    });

    test('test scan verb with emoji in forAtSign and regular expression', () {
      var verb = Scan();
      var command = 'scan:@🐼 ^@kevin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[FOR_AT_SIGN], '@🐼');
      expect(paramsMap[AT_REGEX], '^@kevin');
    });
  });

  group('A group of mock tests to verify scan verb', () {
    late ScanVerbHandler scanVerbHandler;
    late ResponseHandlerManager mockResponseHandlerManager;
    late InboundConnection inboundConnection;
    setUp(() {
      scanVerbHandler = ScanVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();
      inboundConnection = DummyInboundConnection()
        ..metadata = (InboundConnectionMetadata()..isAuthenticated = true);
    });
    test(
        'A test to verify public hidden keys are returned when showhidden set to true',
        () async {
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan:showhidden:true', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList.contains('public:__phone.wavi@alice'), true);
      expect(scanResponseList.contains('_mobile.wavi@alice'), true);
    });

    test(
        'A test to verify public hidden keys are not returned when showhidden set to false',
        () async {
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan:showhidden:false', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList.contains('public:__phone.wavi@alice'), false);
      expect(scanResponseList.contains('_mobile.wavi@alice'), false);
    });
  });

  group('A group of APKAM enrollment tests', () {
    late ScanVerbHandler scanVerbHandler;
    late ResponseHandlerManager mockResponseHandlerManager;
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify scan does not return the enrollment keys when enrollment namespace has __manage',
        () async {
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'__manage': 'r', 'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      await secondaryKeyStore.put(
          'public:firstName.wavi$alice', AtData()..data = 'alice');

      scanVerbHandler = ScanVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();
      // Set enrollmentId to the inboundConnection to mimic the APKAM auth
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = enrollmentId;
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList, isNotEmpty);
      expect(
          scanResponseList
              .contains('$enrollmentId.new.enrollments.__manage@alice'),
          false);
    });

    test(
        'A test to verify scan returns only the keys whose namespaces are authorized in enrollment request',
        () async {
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'__manage': 'r', 'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      // Insert key with wavi and buzz namespace
      await secondaryKeyStore.put(
          'firstName.wavi$alice', AtData()..data = 'alice');
      await secondaryKeyStore.put(
          'mobileNumber.buzz$alice', AtData()..data = '+1 434 543 3232');

      scanVerbHandler = ScanVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();
      // Set enrollmentId to the inboundConnection to mimic the APKAM auth
      (inboundConnection.getMetaData() as InboundConnectionMetadata)
          .enrollmentId = enrollmentId;
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList.length, 1);
      expect(scanResponseList[0], 'firstname.wavi$alice');
    });

    test(
        'A test to verify scan returns enrollment keys on a CRAM authenticated connection',
        () async {
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      inboundConnection.getMetaData().authType = AuthType.cram;
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'__manage': 'r', 'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      scanVerbHandler = ScanVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList.length, 1);
      expect(
          scanResponseList[0], '$enrollmentId.new.enrollments.__manage$alice');
    });

    test('A test to verify enrollment has *:rw access', () async {
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      inboundConnection.getMetaData().authType = AuthType.cram;
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      scanVerbHandler = ScanVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList[0].toString().startsWith(enrollmentId), true);
    });

    test(
        'A test to verify multiple app access in enrollment buzz:r, wavi:rw, atmosphere:rw',
        () async {
      inboundConnection.getMetaData().isAuthenticated = true;
      inboundConnection.getMetaData().sessionID = 'dummy_session';
      inboundConnection.getMetaData().authType = AuthType.cram;
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'buzz': 'r', 'wavi': 'rw', 'atmosphere': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      // Inserting wavi
      await secondaryKeyStore.put(
          'phone.wavi$alice', AtData()..data = '+455 677 8789');
      // Inserting buzz
      await secondaryKeyStore.put(
          'mobile.buzz$alice', AtData()..data = '+544 545 4545');
      // Inserting atmosphere
      await secondaryKeyStore.put(
          'firstname.atmosphere$alice', AtData()..data = 'alice');

      scanVerbHandler = ScanVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      mockResponseHandlerManager = MockResponseHandlerManager();
      scanVerbHandler.responseManager = mockResponseHandlerManager;
      await scanVerbHandler.process('scan', inboundConnection);
      List scanResponseList = jsonDecode(scanResponse);
      expect(scanResponseList[0].toString().startsWith(enrollmentId), true);
      expect(scanResponseList[1], 'firstname.atmosphere$alice');
      expect(scanResponseList[2], 'mobile.buzz$alice');
      expect(scanResponseList[3], 'phone.wavi$alice');
    });
    tearDown(() async => await verbTestsTearDown());
  });
}
