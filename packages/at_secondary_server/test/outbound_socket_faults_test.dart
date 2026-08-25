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
  bool destroyed = false;

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
    destroyed = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
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

    test('an answer arriving after the caller gave up does not answer the next'
        ' one', () async {
      var socket = InjectableSocket();
      var client = clientOn(socket);
      client.lookupTimeoutMillis = 200;

      await expectLater(() => client.lookUp('all:x@alice', handshake: false),
          throwsA(predicate((dynamic e) => e is AtTimeoutException)));

      socket.emit('data:TOO_LATE\n@alice@');
      await Future.delayed(Duration(milliseconds: 30));

      await expectLater(
          () => client.messageListener.read(maxWaitMilliSeconds: 300),
          throwsA(predicate((dynamic e) => e is AtConnectException)),
          reason: 'the request it belonged to is over; returning it would'
              ' answer a different caller with it');
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
