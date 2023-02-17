import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/response/default_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/response_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';
import 'package:mocktail/mocktail.dart';

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

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();

  group('A group of scan verb tests', () {
    test('test scan getVerb', () {
      var handler = ScanVerbHandler(mockKeyStore, mockOutboundClientManager);
      var verb = handler.getVerb();
      expect(verb is Scan, true);
    });

    test('test scan command accept test', () {
      var command = 'scan';
      var handler = ScanVerbHandler(mockKeyStore, mockOutboundClientManager);
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
      var handler = ScanVerbHandler(mockKeyStore, mockOutboundClientManager);
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
      var defaultVerbHandlerManager = DefaultVerbHandlerManager(mockKeyStore, mockOutboundClientManager);

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
      scanVerbHandler = ScanVerbHandler(mockKeyStore, mockOutboundClientManager);
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
}
