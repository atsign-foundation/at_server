import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:fake_async/fake_async.dart';
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
    when(() => mockOutboundConnection.closed)
        .thenAnswer((_) => Completer<void>().future);
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

  group('the framing trade, pinned so it is a decision and not folklore', () {
    test('a raw body containing a newline followed by an atSign is split',
        () async {
      var l = OutboundMessageListener(mockOutboundClient);

      // No producer emits this: every response an outbound client can receive
      // is prefixed and framed by a response handler, and the only raw values
      // it reads are the pol handshake's, which are base64. Pinned so that if
      // it ever becomes reachable, this test says what was traded away.
      await l.messageHandler('data:line one\n@still the same value\n$alice@'
          .codeUnits);

      expect(await l.read(), 'data:line one',
          reason: 'the newline-then-@ pair ends a message, which is what buys'
              ' independence from where the network cuts the bytes');
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

    test('bytes that are not valid UTF-8 close the connection rather than'
        ' throwing out of the handler', () async {
      var l = OutboundMessageListener(mockOutboundClient);

      // Must not throw: this runs as a socket onData callback, and an escape
      // becomes an unhandled rejection.
      await l.messageHandler([0xFF, 0xFE, 0x0A, 0x40]);

      verify(() => mockOutboundClient.close()).called(1);
    }, );

    test('a peer that sends undecodable bytes is not waited on', () async {
      var l = OutboundMessageListener(mockOutboundClient);
      when(() => mockAtConnectionMetaData.isClosed).thenReturn(true);

      await expectLater(() => l.read(maxWaitMilliSeconds: 10000),
          throwsA(predicate((dynamic e) => e is AtConnectException)),
          reason: 'dropping the message and leaving the connection up would'
              ' make every caller queued on this client wait out the whole'
              ' silence budget for an answer that is never coming');
      when(() => mockAtConnectionMetaData.isClosed).thenReturn(false);
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

    test('an emoji atSign\'s prompt is not reported as a fault', () async {
      // Before the listener is built: AtSignLogger takes its level at
      // construction, so a listener made first stays at the suite's 'shout'
      // and never emits the warning this asserts the absence of.
      AtSignLogger.root_level = 'warning';
      var l = OutboundMessageListener(mockOutboundClient);
      var warnings = <String>[];
      var sub = l.logger.logger.onRecord.listen((r) {
        if (r.level >= logging.Level.WARNING) warnings.add(r.message);
      });

      // An atSign is bounded at 55 CHARACTERS. In UTF-8 that is up to four
      // bytes each, so a legitimate prompt is far larger than a
      // character-sized guess at its length.
      var emojiAtSign = '@${'🛠' * 20}';
      // utf8.encode, NOT codeUnits: an emoji is outside the BMP, so codeUnits
      // yields UTF-16 surrogate pairs rather than the bytes a socket carries,
      // and the buffer would never reach the size under test.
      await l.messageHandler(utf8.encode('data:FIRST\n$emojiAtSign@'));
      expect(await l.read(), 'data:FIRST');
      l.beginExchange();
      await sub.cancel();
      AtSignLogger.root_level = 'shout';

      expect(warnings.where((w) => w.contains('left over')), isEmpty,
          reason: 'the prompt of an emoji atSign is an ordinary prompt; a'
              ' byte-sized cap judged against a character bound would call'
              ' every one of them a leftover');
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

  /// These run the real client, connection and listener over an
  /// [InjectableSocket], on a fake clock, so "with no time passing" means the
  /// clock did not move at all between the event and read settling.
  group('Given read is waiting for a response', () {
    setUp(_useLongOutboundIdleTime);

    test('when the response arrives, then read returns it with no time passing',
        () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        async.flushMicrotasks();
        expect(read.done, false, reason: 'nothing has arrived yet');

        socket.emit('data:ANSWER\n@alice@');
        async.flushMicrotasks();

        expect(read.value, 'data:ANSWER');
        expect(async.elapsed, Duration.zero);
      });
    });

    test(
        'when an error response arrives, then read throws its exception with no'
        ' time passing', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        async.flushMicrotasks();
        expect(read.done, false, reason: 'nothing has arrived yet');

        socket.emit('error:{"errorCode":"AT0015","errorDescription":"no such'
            ' key"}\n@alice@');
        async.flushMicrotasks();

        expect(read.error, isA<KeyNotFoundException>());
        expect(async.elapsed, Duration.zero);
      });
    });

    test(
        'when the peer closes the connection, then read throws'
        ' AtConnectException with no time passing', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        async.flushMicrotasks();
        expect(read.done, false, reason: 'nothing has arrived yet');

        socket.emitDone();
        async.flushMicrotasks();

        expect(read.error, isA<AtConnectException>());
        expect(async.elapsed, Duration.zero);
      });
    });

    test(
        'when this side closes the connection, then read throws'
        ' AtConnectException with no time passing', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var client = _clientOn(socket);
        var read = _Settled(client.messageListener.read());
        async.flushMicrotasks();
        expect(read.done, false, reason: 'nothing has arrived yet');

        client.close();
        async.flushMicrotasks();

        expect(read.error, isA<AtConnectException>());
        expect(async.elapsed, Duration.zero);
      });
    });

    test('when the peer answers and then closes, then read returns the answer',
        () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        async.flushMicrotasks();

        socket.emit('data:ANSWERED\n');
        socket.emitDone();
        async.elapse(Duration(milliseconds: 50));

        expect(read.value, 'data:ANSWERED',
            reason: 'the peer answered before hanging up, so the close must'
                ' not be reported over the top of the answer');
      });
    });

    test(
        'when a chunk arrives that does not complete a response, then read'
        ' keeps waiting', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        async.flushMicrotasks();

        socket.emit('data:PART');
        async.elapse(Duration(milliseconds: 100));
        expect(read.done, false,
            reason: 'half a response is not an answer to return');

        socket.emit('IAL\n@alice@');
        async.flushMicrotasks();
        expect(read.value, 'data:PARTIAL');
      });
    });

    test(
        'when nothing arrives for the inter-chunk budget, then read throws'
        ' AtTimeoutException as the budget passes', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read(
            maxWaitMilliSeconds: 10000, transientWaitTimeMillis: 300));
        async.flushMicrotasks();

        async.elapse(Duration(milliseconds: 300));
        expect(read.done, false, reason: 'the budget has not yet passed');
        async.elapse(Duration(milliseconds: 2));

        expect(read.error, isA<AtTimeoutException>());
        expect('${read.error}', contains('Nothing received for 300 millis'));
      });
    });

    test(
        'when the whole exchange outlasts its total budget, then read throws'
        ' AtTimeoutException as the budget passes', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read(
            maxWaitMilliSeconds: 500, transientWaitTimeMillis: 300));
        async.flushMicrotasks();

        async.elapse(Duration(milliseconds: 200));
        socket.emit('data:STILL');
        async.elapse(Duration(milliseconds: 200));
        socket.emit('COMING');
        async.elapse(Duration(milliseconds: 100));
        expect(read.done, false, reason: 'the budget has not yet passed');
        async.elapse(Duration(milliseconds: 2));

        expect(read.error, isA<AtTimeoutException>());
        expect('${read.error}', contains('No response after 500 millis'));
      });
    });
  });

  group('Given a response arrived before read was called', () {
    setUp(_useLongOutboundIdleTime);

    test(
        'when read is called, then it returns that response with no time'
        ' passing', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var client = _clientOn(socket);
        socket.emit('data:EARLY\n@alice@');
        async.flushMicrotasks();

        var read = _Settled(client.messageListener.read());
        async.flushMicrotasks();

        expect(read.value, 'data:EARLY');
        expect(async.elapsed, Duration.zero);
      });
    });
  });

  group('Given a peer that misbehaves while read waits', () {
    setUp(_useLongOutboundIdleTime);

    test(
        'when a reply trickles in one byte at a time inside the inter-chunk'
        ' budget, then read returns it whole when its last byte arrives', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket)
            .messageListener
            .read(maxWaitMilliSeconds: 10000, transientWaitTimeMillis: 300));
        async.flushMicrotasks();

        var bytes = utf8.encode('data:TRICKLED\n@alice@');
        // The reply is complete once the newline and the `@` after it are in.
        var lastNeeded = bytes.indexOf(10) + 1;
        for (var i = 0; i <= lastNeeded; i++) {
          async.elapse(Duration(milliseconds: 200));
          expect(read.done, false,
              reason: 'only $i of the reply\'s bytes had arrived');
          socket.emitBytes([bytes[i]]);
          async.flushMicrotasks();
        }

        expect(read.value, 'data:TRICKLED');
        expect(async.elapsed,
            Duration(milliseconds: 200 * (lastNeeded + 1)),
            reason: 'read returns as the last byte arrives, not later');
      });
    });

    test(
        'when a reply stalls part way for longer than the inter-chunk budget,'
        ' then read throws AtTimeoutException as the budget passes', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket)
            .messageListener
            .read(maxWaitMilliSeconds: 10000, transientWaitTimeMillis: 300));
        async.elapse(Duration(milliseconds: 100));
        socket.emit('data:HAL');

        async.elapse(Duration(milliseconds: 300));
        expect(read.done, false,
            reason: 'the budget runs from the last chunk, 300 ms ago');
        async.elapse(Duration(milliseconds: 2));

        expect(read.error, isA<AtTimeoutException>());
        expect('${read.error}', contains('Nothing received for 300 millis'));
      });
    });

    test(
        'when the peer hangs up part way through a reply, then read throws'
        ' AtConnectException with no time passing', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        socket.emit('data:HALF');
        async.flushMicrotasks();
        expect(read.done, false, reason: 'half a reply is not an answer');

        socket.emitDone();
        async.flushMicrotasks();

        expect(read.error, isA<AtConnectException>());
        expect(async.elapsed, Duration.zero);
      });
    });

    test(
        'when the socket errors, then read throws AtConnectException with no'
        ' time passing', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        async.flushMicrotasks();

        socket.emitError(SocketException('Connection reset by peer'));
        async.flushMicrotasks();

        expect(read.error, isA<AtConnectException>());
        expect(async.elapsed, Duration.zero);
      });
    });

    test(
        'when the peer sends bytes that are not UTF-8, then read throws'
        ' AtConnectException with no time passing', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var read = _Settled(_clientOn(socket).messageListener.read());
        async.flushMicrotasks();

        socket.emitBytes([...utf8.encode('data:'), 0xff, 0x0a, 0x40]);
        async.flushMicrotasks();

        expect(read.error, isA<AtConnectException>());
        expect(async.elapsed, Duration.zero);
      });
    });
  });

  group('Given read timed out waiting for a reply', () {
    setUp(_useLongOutboundIdleTime);

    test('when the reply arrives late, then it does not answer the next exchange',
        () {
      fakeAsync((async) {
        var socket = _ReplyInFlightAtCloseSocket('data:LATE\n@alice@');
        var listener = _clientOn(socket).messageListener;
        var first = _Settled(
            listener.read(maxWaitMilliSeconds: 10000, transientWaitTimeMillis: 300));
        async.elapse(Duration(milliseconds: 302));
        expect(first.error, isA<AtTimeoutException>());
        expect(socket.destroyed, true,
            reason: 'timing out closes the connection, which is when the reply'
                ' in flight is delivered');

        async.flushMicrotasks();
        var next = _Settled(listener.read());
        async.flushMicrotasks();

        expect(next.value, isNull,
            reason: 'the late reply answered a request nobody is waiting on');
        expect(next.error, isA<AtConnectException>());
      });
    });
  });

  group('Given a connection that has carried many exchanges', () {
    setUp(_useLongOutboundIdleTime);

    test(
        'when a thousand replies have each been read, then no timer is left'
        ' pending', () {
      fakeAsync((async) {
        var socket = InjectableSocket();
        var listener = _clientOn(socket).messageListener;
        for (var i = 0; i < 1000; i++) {
          var read = _Settled(listener.read());
          async.flushMicrotasks();
          socket.emit('data:R$i\n@alice@');
          async.flushMicrotasks();
          expect(read.value, 'data:R$i');
        }

        expect(async.pendingTimers, isEmpty,
            reason: 'each wait must leave nothing behind once it is answered');
      });
    });
  });
}

/// Long, so nothing under test is invalidated by going idle.
void _useLongOutboundIdleTime() {
  var serverContext = AtSecondaryContext();
  serverContext.unauthenticatedOutboundIdleTimeMillis = 60000;
  AtSecondaryServerImpl.getInstance().serverContext = serverContext;
}

/// A client wired to [socket] with its listener attached, as `connect()`
/// would leave it.
OutboundClient _clientOn(InjectableSocket socket) {
  var client = OutboundClient(
    InboundConnectionImpl(FakeSocket(), 'alice'),
    'alice',
    AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
    false,
    DefaultOutboundConnectionFactory(clientCertificateRequired: false),
  )..outboundConnection = OutboundConnectionImpl(socket, 'alice');
  client.messageListener = OutboundMessageListener(client);
  client.messageListener.listen();
  return client;
}

/// A socket with a reply still in flight when this side destroys it, so the
/// reply is delivered after the close, as already-queued socket events are.
class _ReplyInFlightAtCloseSocket extends InjectableSocket {
  final String inFlight;

  _ReplyInFlightAtCloseSocket(this.inFlight);

  @override
  void destroy() {
    if (!destroyed) {
      emit(inFlight);
    }
    super.destroy();
  }
}

/// How a future settled, recorded as it happens, so a test on a fake clock
/// can ask whether it has settled yet.
class _Settled<T> {
  bool done = false;
  T? value;
  Object? error;

  _Settled(Future<T> future) {
    future.then((v) {
      value = v;
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    });
  }
}
