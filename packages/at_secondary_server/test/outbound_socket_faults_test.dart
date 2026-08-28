import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// A socket whose every fault can be injected: what it delivers, when, whether
/// it errors, and whether it ends.
///
/// The rest of the outbound tests drive [OutboundMessageListener.messageHandler]
/// directly, which cannot reach `onDone`, `onError`, or anything about timing.
/// These go through `listen()` so the whole path is exercised as the runtime
/// wires it.
class InjectableSocket extends Fake implements Socket {
  final _controller = StreamController<Uint8List>();
  final Completer<void> _doneCompleter = Completer<void>();

  /// Everything the server wrote to this socket, in order.
  final List<String> written = [];

  /// How many times the server destroyed this socket. A count rather than a
  /// flag, so a double-close is visible.
  int destroyCount = 0;
  bool get destroyed => destroyCount > 0;

  void emit(String data) =>
      _controller.add(Uint8List.fromList(utf8.encode(data)));

  void emitBytes(List<int> bytes) =>
      _controller.add(Uint8List.fromList(bytes));

  void emitError(Object error) => _controller.addError(error);

  /// The peer hangs up.
  Future<void> emitDone() => _controller.close();

  @override
  Future get done => _doneCompleter.future;

  @override
  void destroy() {
    destroyCount++;
    // A real Socket.destroy() tears down the read side too, so the close the
    // server performs comes back to it as onDone. Without this the double
    // exercises only half of what the runtime does on every close path.
    if (!_controller.isClosed) _controller.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  /// Delivers [data] and destroys in the same turn -- the one production route
  /// to bytes arriving after a close, since already-queued events still
  /// dispatch after the controller is closed.
  void emitThenDestroy(String data) {
    emit(data);
    destroy();
  }

  @override
  void write(Object? obj) => written.add(obj.toString());

  @override
  InternetAddress get remoteAddress => InternetAddress('127.0.0.1');
  @override
  int get remotePort => 9999;
  @override
  InternetAddress get address => InternetAddress('127.0.0.1');
  @override
  int get port => 5555;
  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _controller.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Future<void> close() async {}
}

void main() {
  verbTestsSetUpLogging();

  setUp(() {
    var serverContext = AtSecondaryContext();
    // Long, so nothing under test is invalidated by going idle.
    serverContext.unauthenticatedOutboundIdleTimeMillis = 60000;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
  });

  /// A client wired to [socket] with its listener attached, as `connect()`
  /// would leave it.
  OutboundClient clientOn(InjectableSocket socket) {
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

  group('the peer hangs up', () {
    test('a complete response already sent is still delivered', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      socket.emit('data:ANSWERED\n');
      await Future.delayed(Duration(milliseconds: 20));
      await socket.emitDone();
      await Future.delayed(Duration(milliseconds: 20));

      expect(await client.messageListener.read(maxWaitMilliSeconds: 500),
          'data:ANSWERED',
          reason: 'the peer answered and then hung up -- it still answered, and'
              ' the close must not be reported over the top of it');
    });

    test('closes the connection', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      await socket.emitDone();
      await Future.delayed(Duration(milliseconds: 20));

      expect(client.outboundConnection!.metaData.isClosed, true);
    });

    test('a caller waiting on it fails fast rather than waiting the budget',
        () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      var stopwatch = Stopwatch()..start();
      var read = client.messageListener.read(maxWaitMilliSeconds: 10000);
      await Future.delayed(Duration(milliseconds: 20));
      await socket.emitDone();

      await expectLater(read,
          throwsA(predicate((dynamic e) => e is AtConnectException)));
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(3000),
          reason: 'once the socket is gone no response can arrive, so waiting'
              ' out the budget serves nobody');
    });

    test('bytes arriving on a connection already closed are dropped', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      // A read timeout closes the connection while the socket itself is still
      // live and may still deliver. (A socket cannot deliver after `done`, so
      // that is not the shape to test -- this is.)
      client.outboundConnection!.metaData.isClosed = true;
      socket.emit('data:GHOST\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));

      // A later caller on a recycled client must not find it waiting.
      client.outboundConnection!.metaData.isClosed = false;
      await expectLater(
          () => client.messageListener.read(maxWaitMilliSeconds: 300),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)),
          reason: 'a response that arrived on a dead connection belongs to'
              ' nobody and must not be handed to whoever reads next');
    });
  });

  group('the socket errors', () {
    test('a stream error closes the connection', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      socket.emitError(SocketException('injected'));
      await Future.delayed(Duration(milliseconds: 50));

      expect(client.outboundConnection!.metaData.isClosed, true);
      expect(socket.destroyed, true);
    });

    test('an error that is not an Exception still closes the connection',
        () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      socket.emitError('a bare string, which a socket may deliver');
      await Future.delayed(Duration(milliseconds: 50));

      expect(client.outboundConnection!.metaData.isClosed, true,
          reason: 'the error handler must not itself depend on the error being'
              ' a particular type');
    });

    test('undecodable bytes close the connection instead of stalling a caller',
        () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      var stopwatch = Stopwatch()..start();
      var read = client.messageListener
          .read(maxWaitMilliSeconds: 20000, transientWaitTimeMillis: 10000);
      await Future.delayed(Duration(milliseconds: 20));
      socket.emitBytes([0xFF, 0xFE, 0x0A, 0x40]);

      await expectLater(
          read, throwsA(predicate((dynamic e) => e is AtConnectException)));
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(5000),
          reason: 'the caller must not wait out the silence budget holding the'
              ' request/response mutex, with everything queued behind it');
      expect(client.outboundConnection!.metaData.isClosed, true);
    });

    test('a chunk bigger than the buffer closes the connection rather than'
        ' escaping the socket callback', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      socket.emitBytes(List.filled(10240001, 65));
      await Future.delayed(Duration(milliseconds: 300));

      expect(client.outboundConnection!.metaData.isClosed, true,
          reason: 'messageHandler throws BufferOverFlowException from inside an'
              ' async onData; runZonedGuarded must route it to the error'
              ' handler rather than let it become an unhandled rejection');
      await expectLater(
          () => client.messageListener.read(maxWaitMilliSeconds: 300),
          throwsA(predicate((dynamic e) => e is AtConnectException)));
    });
  });

  group('the peer stops answering', () {
    test('a caller queued behind a timed-out one fails immediately, not after'
        ' its own budget', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);
      client.lookupTimeoutMillis = 300;

      var stopwatch = Stopwatch()..start();
      var first = client
          .lookUp('all:first@alice', handshake: false)
          .then((v) => 'ok')
          .catchError((Object e) => e.runtimeType.toString());
      var second = client
          .lookUp('all:second@alice', handshake: false)
          .then((v) => 'ok')
          .catchError((Object e) => e.runtimeType.toString());

      expect(await first, 'AtTimeoutException');
      var firstAt = stopwatch.elapsedMilliseconds;
      expect(await second, 'OutBoundConnectionInvalidException');
      var secondAt = stopwatch.elapsedMilliseconds;

      expect(secondAt - firstAt, lessThan(200),
          reason: 'a hanging peer costs one budget in total, not one per'
              ' queued caller: the timeout closes the connection and everything'
              ' behind it then fails at once');
      expect(socket.written.length, 1,
          reason: 'the second request must never reach a dead socket');
    });

    test('the peer cannot answer at all once the caller has given up', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);
      client.lookupTimeoutMillis = 200;

      await expectLater(() => client.lookUp('all:x@alice', handshake: false),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)));

      // The timeout destroys the socket, which tears down the read side, so a
      // late answer cannot reach us -- attempting to deliver one is a state
      // the transport does not permit. Pinned because an earlier version of
      // this double completed `done` without closing the stream, which made
      // the unreachable look reachable.
      expect(socket.destroyed, true);
      expect(() => socket.emit('data:TOO_LATE\n@alice@'), throwsStateError,
          reason: 'no bytes can arrive on a destroyed socket');
    });

    test('an answer already in flight when the socket dies is still delivered',
        () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      // Delivered and then destroyed in the same turn: the peer answered, and
      // the connection died immediately afterwards.
      socket.emitThenDestroy('data:IN_FLIGHT\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));

      expect(await client.messageListener.read(maxWaitMilliSeconds: 300),
          'data:IN_FLIGHT',
          reason: 'the queue is checked before the connection state, because a'
              ' peer that answered and then died has still answered');
    });
  });

  group('a connection that was replaced', () {
    /// Swaps in a new connection and listener exactly as
    /// OutboundClient._createConnectionAndListener does, leaving the previous
    /// listener still subscribed to the previous socket.
    OutboundClient reconnect(OutboundClient client, InjectableSocket next) {
      client.outboundConnection = OutboundConnectionImpl(next, 'alice');
      client.messageListener = OutboundMessageListener(client);
      client.messageListener.listen();
      return client;
    }

    test('does not take the replacement down when its old socket ends',
        () async {
      var first = InjectableSocket();
      var client = clientOn(first);
      var second = InjectableSocket();
      reconnect(client, second);

      // The abandoned socket finally hangs up.
      await first.emitDone();
      await Future.delayed(Duration(milliseconds: 30));

      expect(client.outboundConnection!.metaData.isClosed, false,
          reason: 'the listener left behind must close the connection IT was'
              ' made for, not whichever one the client holds now');
      expect(second.destroyCount, 0);

      second.emit('data:STILL_WORKING\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));
      expect(await client.messageListener.read(maxWaitMilliSeconds: 300),
          'data:STILL_WORKING');
    });

    test('does not take the replacement down when its old socket errors',
        () async {
      var first = InjectableSocket();
      var client = clientOn(first);
      var second = InjectableSocket();
      reconnect(client, second);

      first.emitError(SocketException('the abandoned socket faults'));
      await Future.delayed(Duration(milliseconds: 50));

      expect(client.outboundConnection!.metaData.isClosed, false);
      second.emit('data:STILL_WORKING\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));
      expect(await client.messageListener.read(maxWaitMilliSeconds: 300),
          'data:STILL_WORKING');
    });

    test('late bytes on the old socket do not reach the new exchange',
        () async {
      var first = InjectableSocket();
      var client = clientOn(first);
      var second = InjectableSocket();
      reconnect(client, second);

      first.emit('data:FROM_THE_OLD_SOCKET\n@alice@');
      second.emit('data:FROM_THE_NEW_SOCKET\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));

      expect(await client.messageListener.read(maxWaitMilliSeconds: 300),
          'data:FROM_THE_NEW_SOCKET',
          reason: 'the old socket has its own listener and its own queue; its'
              ' traffic must not surface on the current one');
    });
  });

  group('pathological delivery', () {
    test('a response arriving one byte per socket event is reassembled',
        () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      for (var byte in utf8.encode('data:{"k":"v@w"}\n@alice@')) {
        socket.emitBytes([byte]);
      }
      await Future.delayed(Duration(milliseconds: 50));

      expect(await client.messageListener.read(maxWaitMilliSeconds: 500),
          'data:{"k":"v@w"}',
          reason: 'framing must not depend on how the socket chunks the bytes');
    });

    test('several responses in one socket event are separate answers',
        () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      socket.emit('data:A\n@alice@data:B\n@alice@data:C\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));

      expect(await client.messageListener.read(maxWaitMilliSeconds: 500), 'data:A');
      expect(await client.messageListener.read(maxWaitMilliSeconds: 500), 'data:B');
      expect(await client.messageListener.read(maxWaitMilliSeconds: 500), 'data:C');
    });

    test('events arriving faster than the read poll are all kept', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      // Twenty responses with no yield between them: far more than the 10ms
      // poll can take one at a time.
      for (var i = 0; i < 20; i++) {
        socket.emit('data:R$i\n@alice@');
      }
      await Future.delayed(Duration(milliseconds: 50));

      for (var i = 0; i < 20; i++) {
        expect(await client.messageListener.read(maxWaitMilliSeconds: 500),
            'data:R$i',
            reason: 'the queue must preserve every message and their order');
      }
    });

    test('a zero-length socket event is survivable', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);

      socket.emitBytes(<int>[]);
      socket.emit('data:AFTER\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));

      expect(await client.messageListener.read(maxWaitMilliSeconds: 500),
          'data:AFTER',
          reason: 'an empty event must not take the connection down');
      expect(client.outboundConnection!.metaData.isClosed, false);
    });
  });
}
