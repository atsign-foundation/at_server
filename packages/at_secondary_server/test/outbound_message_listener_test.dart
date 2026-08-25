import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'test_utils.dart';

class MockOutboundClient extends Mock implements OutboundClient {}

class MockOutboundConnectionImpl extends Mock
    implements OutboundConnectionImpl {}

class MockAtConnectionMetaData extends Mock implements AtConnectionMetaData {}

void main() async {
  verbTestsSetUpLogging();

  // mock object for outbound client
  OutboundClient mockOutboundClient = MockOutboundClient();
  OutboundSocketConnection mockOutboundConnection =
      MockOutboundConnectionImpl();
  AtConnectionMetaData mockAtConnectionMetaData = MockAtConnectionMetaData();
  setUp(() {
    reset(mockOutboundClient);
    when(() => mockOutboundClient.toAtSign).thenReturn(alice);
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
          .messageHandler('data:phone$alice\n$alice@'.codeUnits);
      var response = await outboundMessageListener.read();
      expect(response, 'data:phone$alice');
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
          'error:AT0015-Exception.key not found : phone$alice does not exist in keystore\n$alice@'
              .codeUnits);

      expect(
          () async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) =>
              e is KeyNotFoundException &&
              e.message ==
                  'Exception.key not found : phone$alice does not exist in keystore')));
    });
    test('A test to validate error response json throws KeyNotFoundException',
        () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener.messageHandler(
          'error:{"errorCode":"AT0015","errorDescription":"key not found: public:no-key$alice does not exist in keystore"}\n$alice@'
              .codeUnits);

      expect(
          () async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) =>
              e is KeyNotFoundException &&
              e.message ==
                  'key not found: public:no-key$alice does not exist in keystore')));
    });

    test('A test to invalid response throws AtConnectException', () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener
          .messageHandler('test:invalid response\n$alice@'.codeUnits);

      expect(() async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) => e is AtConnectException)));
    });

    test('A test to validate error response string without error code',
        () async {
      OutboundMessageListener outboundMessageListener =
          OutboundMessageListener(mockOutboundClient);
      await outboundMessageListener.messageHandler(
          'error: key not found : phone$alice does not exist in keystore\n$alice@'
              .codeUnits);
      expect(
          () async => await outboundMessageListener.read(),
          throwsA(predicate((dynamic e) =>
              e is AtConnectException &&
              e.message ==
                  'Request to remote secondary $alice at localhost:25000 received error response \' key not found : phone$alice does not exist in keystore\'')));
    });
  });

  /// A response and the prompt that follows it are written by the peer as one
  /// string, but the network may deliver them as two reads. A bare
  /// `@<atSign>@` on an empty buffer is then indistinguishable from the `pol`
  /// response, which is the one response shaped that way — so the client
  /// declares when it is expecting one.
  group('a prompt segmented away from the response it follows', () {
    test('is not queued as a response when no handshake prompt is expected',
        () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      await listener.messageHandler('data:phone$alice\n'.codeUnits);
      await listener.messageHandler('$alice@'.codeUnits);

      expect(await listener.read(), 'data:phone$alice');
      // The prompt must not be sitting in the queue behind it.
      await expectLater(() => listener.read(maxWaitMilliSeconds: 200),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)),
          reason: 'the trailing prompt carries no payload and no caller is'
              ' waiting for it, so nothing should remain to be read');
    });

    test('leaves the next exchange answered by its own response', () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      // First exchange: response and prompt arrive as separate reads.
      await listener.messageHandler('data:FIRST\n'.codeUnits);
      await listener.messageHandler('$alice@'.codeUnits);
      expect(await listener.read(), 'data:FIRST');

      // Second exchange, answered normally.
      await listener.messageHandler('data:SECOND\n$alice@'.codeUnits);
      expect(await listener.read(), 'data:SECOND',
          reason: 'the second exchange must be answered with its own response,'
              ' not with the prompt left over from the first');
    });

    test('is delivered when the client IS expecting a handshake prompt',
        () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      listener.expectingHandshakePrompt = true;
      await listener.messageHandler('$alice@'.codeUnits);

      expect(await listener.read(), '$alice@',
          reason: 'the pol response is a bare prompt and must still be'
              ' readable while the handshake is in flight');
    });

    test('queued during a handshake is refused once the handshake is over',
        () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      // A pol prompt that was queued but never consumed — the handshake gave
      // up between the queue and the read — and the flag has since cleared.
      listener.expectingHandshakePrompt = true;
      await listener.messageHandler('$alice@'.codeUnits);
      listener.expectingHandshakePrompt = false;

      expect(() async => await listener.read(maxWaitMilliSeconds: 200),
          throwsA(predicate((dynamic e) => e is AtConnectException)),
          reason: 'a bare prompt is not an answer to an ordinary request, so'
              ' it must fail loudly rather than be handed back as data');
    });
  });

  group('a partial response left behind by a failed read', () {
    test('does not prefix the response the next exchange reads', () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      // A response that never terminates, so nothing is ever queued and the
      // caller gives up with the fragment still in the buffer.
      await listener.messageHandler('data:half-a-respon'.codeUnits);
      await expectLater(() => listener.read(maxWaitMilliSeconds: 200),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)));

      // The next exchange must be answered with its own response, whole.
      await listener.messageHandler('data:NEXT\n$alice@'.codeUnits);
      expect(await listener.read(), 'data:NEXT',
          reason: 'a fragment from an exchange that is over must be discarded,'
              ' not carried forward to corrupt the next response');
    });
  });

  group('a mid-response chunk that begins and ends with @', () {
    test('is kept as payload rather than flushing a truncated response',
        () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      // A record whose value contains an atSign, segmented so that the middle
      // chunk both begins and ends with '@'. It is payload, not a prompt.
      await listener.messageHandler('data:{"k":"a'.codeUnits);
      await listener.messageHandler('@bob.and.@'.codeUnits);
      await listener.messageHandler('carol"}\n$alice@'.codeUnits);

      expect(await listener.read(), 'data:{"k":"a@bob.and.@carol"}',
          reason: 'every byte of the response must survive reassembly: a chunk'
              ' is only a prompt when the buffer is empty');
    });
  });
}
