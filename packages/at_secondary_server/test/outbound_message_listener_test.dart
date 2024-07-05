import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockOutboundClient extends Mock implements OutboundClient {}

class MockOutboundConnectionImpl extends Mock
    implements OutboundConnectionImpl {}

class MockAtConnectionMetaData extends Mock implements AtConnectionMetaData {}

void main() async {
  // mock object for outbound client
  OutboundClient mockOutboundClient = MockOutboundClient();
  OutboundSocketConnection mockOutboundConnection =
      MockOutboundConnectionImpl();
  AtConnectionMetaData mockAtConnectionMetaData = MockAtConnectionMetaData();
  setUp(() {
    reset(mockOutboundClient);
    when(() => mockOutboundClient.toAtSign).thenReturn('@alice');
    when(() => mockOutboundClient.toPort).thenReturn('25000');
    when(() => mockOutboundClient.toHost).thenReturn('localhost');
    when(() => mockOutboundClient.outboundConnection)
        .thenReturn(mockOutboundConnection);
    when(() => mockOutboundConnection.metaData)
        .thenReturn(mockAtConnectionMetaData);
    when(() => mockAtConnectionMetaData.isStale).thenReturn(false);
    when(() => mockAtConnectionMetaData.isClosed).thenReturn(false);
  });

  group('A group of tests for outbound message listener read', () {
    test('A test to verify valid response', () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener
          .messageHandler('data:phone@alice\n@alice@'.codeUnits);
      var response = await outboundMessageListener.read();
      expect(response, 'data:phone@alice');
    });

    test('A test to validate timeout exception when there is no data to read',
        () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      expect(
          () async =>
              await outboundMessageListener.read(maxWaitMilliSeconds: 500),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)));
    });

    test('A test to validate error response string throws KeyNotFoundException',
        () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener.messageHandler(
          'error:AT0015-Exception.key not found : phone@alice does not exist in keystore\n@alice@'
              .codeUnits);

      expect(
          () async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) =>
              e is KeyNotFoundException &&
              e.message ==
                  'Exception.key not found : phone@alice does not exist in keystore')));
    });
    test('A test to validate error response json throws KeyNotFoundException',
        () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener.messageHandler(
          'error:{"errorCode":"AT0015","errorDescription":"key not found: public:no-key@alice does not exist in keystore"}\n@alice@'
              .codeUnits);

      expect(
          () async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) =>
              e is KeyNotFoundException &&
              e.message ==
                  'key not found: public:no-key@alice does not exist in keystore')));
    });

    test('A test to invalid response throws AtConnectException', () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener
          .messageHandler('test:invalid response\n@alice@'.codeUnits);

      expect(() async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) => e is AtConnectException)));
    });

    test('A test to validate error response string without error code',
        () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener.messageHandler(
          'error: key not found : phone@alice does not exist in keystore\n@alice@'
              .codeUnits);
      expect(
          () async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) =>
              e is AtConnectException &&
              e.message ==
                  'Request to remote secondary @alice at localhost:25000 received error response \' key not found : phone@alice does not exist in keystore\'')));
    });
  });
}
