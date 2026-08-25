import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart' as logging;

import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_logger.dart';
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

  /// read() bounds an exchange two ways: a total budget, and the gap it will
  /// tolerate between chunks. One budget cannot do both jobs — it either cuts
  /// off a response that is still arriving, or waits out the whole budget on a
  /// peer that has stopped answering.
  group('the inter-chunk budget', () {
    test('fires long before the total budget when the peer goes quiet',
        () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      final stopwatch = Stopwatch()..start();
      await expectLater(
          () => listener.read(
              maxWaitMilliSeconds: 10000, transientWaitTimeMillis: 100),
          throwsA(predicate((dynamic e) =>
              e is AtTimeoutException &&
              e.message.contains('Nothing received for 100 millis'))),
          reason: 'a silent peer must be given up on after the inter-chunk'
              ' budget, not after the whole exchange budget');
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(5000),
          reason: 'it must not have waited out the 10s total budget');
    });

    test('is reset by every chunk, so a response still arriving survives',
        () async {
      OutboundMessageListener listener =
          OutboundMessageListener(mockOutboundClient);

      // Four chunks, each gap inside the 300ms inter-chunk budget, together
      // well past it. This succeeds only if each chunk restarts the clock.
      unawaited(() async {
        for (final chunk in ['data:A', 'BB', 'CCC', '\n$alice@']) {
          await Future.delayed(Duration(milliseconds: 120));
          await listener.messageHandler(chunk.codeUnits);
        }
      }());

      expect(
          await listener.read(
              maxWaitMilliSeconds: 10000, transientWaitTimeMillis: 300),
          'data:ABBCCC',
          reason: 'a large response arriving steadily is not a peer that has'
              ' stopped answering, and must not be cut off as one');
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

  /// A response and the prompt that follows it are one write on the peer's
  /// side, delivered in however many pieces the network chooses. These drive
  /// segmentations a well-behaved peer would never produce, because the
  /// framing must not depend on where a chunk happens to end.
  group('segmentation', () {
    test('a payload byte that is an atSign survives on its own chunk',
        () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('data:a'.codeUnits);
      await l.messageHandler('@'.codeUnits);
      await l.messageHandler('b\n$alice@'.codeUnits);
      expect(await l.read(), 'data:a@b',
          reason: 'a lone @ is only a prompt when nothing is part-assembled');
    });

    test('a chunk whose tail is payload keeps its tail', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('data:{"x":1}\nyz@'.codeUnits);
      await l.messageHandler('w\n$alice@'.codeUnits);
      expect(await l.read(), 'data:{"x":1}\nyz@w',
          reason: 'everything after the last newline of a chunk is not a'
              ' prompt just because the chunk happens to end with @');
    });

    test('two responses delivered in one segment are two answers', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('data:A\n$alice@data:B\n$alice@'.codeUnits);
      expect(await l.read(), 'data:A');
      expect(await l.read(), 'data:B',
          reason: 'the second response must not be welded onto the first and'
              ' silently lost');
    });

    test('a response delivered one byte at a time is reassembled', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      for (var b in 'data:{"k":"v@w"}\n$alice@'.codeUnits) {
        await l.messageHandler([b]);
      }
      expect(await l.read(), 'data:{"k":"v@w"}',
          reason: 'the framing must not depend on chunk boundaries at all');
    });

    test('a prompt split in the middle does not swallow its response',
        () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('data:SPLIT\n@ali'.codeUnits);
      await l.messageHandler('ce@'.codeUnits);
      expect(await l.read(), 'data:SPLIT');
    });

    test('a prompt arriving entirely on its own is not a response', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('data:ONLY\n'.codeUnits);
      await l.messageHandler('$alice@'.codeUnits);
      expect(await l.read(), 'data:ONLY');
      await expectLater(() => l.read(maxWaitMilliSeconds: 150),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)),
          reason: 'nothing should remain to be read');
    });
  });

  group('hostile and malformed input', () {
    test('a zero-length chunk is a no-op', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler(<int>[]);
      await l.messageHandler('data:OK\n$alice@'.codeUnits);
      expect(await l.read(), 'data:OK',
          reason: 'indexing an empty chunk would throw out of the socket'
              ' callback and take the connection down');
    });

    test('bytes that are not valid UTF-8 do not throw out of the handler',
        () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler([0xFF, 0xFE, 0x0A, 0x40]);
      await l.messageHandler('data:AFTER\n$alice@'.codeUnits);
      expect(await l.read(), 'data:AFTER',
          reason: 'a malformed message must be dropped, not left in the buffer'
              ' to corrupt every response after it');
    });

    test('a UTF-8 character split across chunks is reassembled', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      // utf8.encode, not codeUnits: 'é' is one UTF-16 unit but TWO UTF-8
      // bytes, and it is the byte sequence the socket delivers.
      var payload = utf8.encode('data:café\n');
      var splitAt = payload.length - 2; // between the two bytes of 'é'
      await l.messageHandler(payload.sublist(0, splitAt));
      await l.messageHandler(payload.sublist(splitAt));
      await l.messageHandler('$alice@'.codeUnits);
      expect(await l.read(), 'data:café',
          reason: 'a character split across two reads must be decoded from the'
              ' reassembled bytes, not from either half');
    });

    test('a bare newline does not become an empty response', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('\n'.codeUnits);
      await l.messageHandler('data:REAL\n$alice@'.codeUnits);
      expect(await l.read(), 'data:REAL',
          reason: 'an empty flush must not be queued, or it tears down the'
              ' next exchange as an unexpected response');
    });

    test('a stream of nothing but prompts is given up on at the inter-chunk'
        ' budget', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      var dripping = true;
      // Keeps dripping well past the inter-chunk budget, with every gap
      // comfortably inside it. If a discarded byte counted as progress the
      // budget would never fire while this runs, and the read would instead
      // survive until the drip stops -- so the ELAPSED time is what
      // discriminates, not the exception on its own.
      unawaited(() async {
        while (dripping) {
          await Future.delayed(Duration(milliseconds: 50));
          await l.messageHandler('@'.codeUnits);
        }
      }());

      var stopwatch = Stopwatch()..start();
      await expectLater(
          () => l.read(
              maxWaitMilliSeconds: 20000, transientWaitTimeMillis: 200),
          throwsA(predicate((dynamic e) =>
              e is AtTimeoutException &&
              e.message.contains('Nothing received'))),
          reason: 'discarded bytes are not progress -- a peer dripping prompts'
              ' must not look like a response still arriving');
      stopwatch.stop();
      dripping = false;
      expect(stopwatch.elapsedMilliseconds, lessThan(2000),
          reason: 'it must give up at the inter-chunk budget while the prompts'
              ' are still arriving, not wait for them to stop');
    });

    test('a chunk larger than the buffer capacity is refused and leaves no'
        ' residue', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await expectLater(l.messageHandler(List.filled(10240001, 65)),
          throwsA(predicate((dynamic e) => e is BufferOverFlowException)));
      await l.messageHandler('data:AFTER\n$alice@'.codeUnits);
      expect(await l.read(), 'data:AFTER');
    });
  });

  group('exchange boundaries', () {
    test('the prompt a completed exchange leaves behind is not reported as a'
        ' fault', () async {
      // The suite runs at 'shout', which is above warning, so a warning
      // would never be emitted and the assertion below would hold for the
      // wrong reason. The companion test is the control that proves it.
      AtSignLogger.root_level = 'warning';
      var l = OutboundMessageListener(mockOutboundClient);
      var warnings = <String>[];
      // Records reach the logger's own stream, not Logger.root's:
      // hierarchicalLoggingEnabled is false in this tree.
      var sub = l.logger.logger.onRecord.listen((r) {
        if (r.level >= logging.Level.WARNING) warnings.add(r.message);
      });

      await l.messageHandler('data:FIRST\n$alice@'.codeUnits);
      expect(await l.read(), 'data:FIRST');
      // The prompt is deliberately retained to be stripped from the next
      // response, so it is present at the start of every later exchange.
      l.beginExchange();
      await sub.cancel();
      AtSignLogger.root_level = 'shout';

      expect(warnings.where((w) => w.contains('left over')), isEmpty,
          reason: 'warning on the normal case makes the diagnostic useless:'
              ' it would fire on every exchange and could never distinguish a'
              ' genuine leftover from designed steady state');
    });

    test('a genuine leftover IS reported', () async {
      AtSignLogger.root_level = 'warning';
      var l = OutboundMessageListener(mockOutboundClient);
      var warnings = <String>[];
      var sub = l.logger.logger.onRecord.listen((r) {
        if (r.level >= logging.Level.WARNING) warnings.add(r.message);
      });

      await l.messageHandler('data:UNCLAIMED\n$alice@'.codeUnits);
      l.beginExchange();
      await sub.cancel();
      AtSignLogger.root_level = 'shout';

      expect(warnings.where((w) => w.contains('left over')), isNotEmpty,
          reason: 'an unread message is exactly what this diagnostic is for');
    });

    test('an unread message does not answer the next exchange', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('data:FIRST\n$alice@'.codeUnits);
      await l.messageHandler('data:UNSOLICITED\n$alice@'.codeUnits);
      expect(await l.read(), 'data:FIRST');

      l.beginExchange();
      await l.messageHandler('data:SECOND\n$alice@'.codeUnits);
      expect(await l.read(), 'data:SECOND',
          reason: 'a message left over from a finished exchange must never be'
              ' handed to the next request as its answer');
    });

    test('a partial message does not prefix the next exchange', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      await l.messageHandler('data:half-a-mess'.codeUnits);
      l.beginExchange();
      await l.messageHandler('data:WHOLE\n$alice@'.codeUnits);
      expect(await l.read(), 'data:WHOLE');
    });
  });

  group('connection state', () {
    test('a response the peer terminated but never prompted is still'
        ' delivered', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      // What the server writes when it is about to hang up: a newline and no
      // prompt (see the connection-limit path in GlobalExceptionHandler).
      await l.messageHandler('data:LAST\n'.codeUnits);
      when(() => mockAtConnectionMetaData.isClosed).thenReturn(true);

      expect(await l.read(maxWaitMilliSeconds: 500), 'data:LAST',
          reason: 'a peer that answers and then hangs up has still answered;'
              ' reporting the close over the top of it loses the answer');
      when(() => mockAtConnectionMetaData.isClosed).thenReturn(false);
    });

    test('a closed connection fails fast rather than waiting the budget',
        () async {
      var l = OutboundMessageListener(mockOutboundClient);
      when(() => mockAtConnectionMetaData.isClosed).thenReturn(true);
      var sw = Stopwatch()..start();
      await expectLater(
          () => l.read(maxWaitMilliSeconds: 10000),
          throwsA(predicate((dynamic e) => e is AtConnectException)));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(5000));
      when(() => mockAtConnectionMetaData.isClosed).thenReturn(false);
    });

    test('a stale connection fails fast rather than waiting the budget',
        () async {
      var l = OutboundMessageListener(mockOutboundClient);
      when(() => mockAtConnectionMetaData.isStale).thenReturn(true);
      var sw = Stopwatch()..start();
      await expectLater(
          () => l.read(maxWaitMilliSeconds: 10000),
          throwsA(predicate((dynamic e) => e is AtConnectException)));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(5000),
          reason: 'a stale connection can no more deliver a response than a'
              ' closed one');
      when(() => mockAtConnectionMetaData.isStale).thenReturn(false);
    });

    test('data arriving on a stale connection is dropped', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      when(() => mockAtConnectionMetaData.isStale).thenReturn(true);
      await l.messageHandler('data:GHOST\n$alice@'.codeUnits);
      when(() => mockAtConnectionMetaData.isStale).thenReturn(false);
      await expectLater(() => l.read(maxWaitMilliSeconds: 150),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)));
    });
  });
}
