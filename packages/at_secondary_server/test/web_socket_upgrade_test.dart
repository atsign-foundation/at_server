import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart' show ConnectionInvalidException;
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/http_request_handler.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart'
    show AuthType, InboundConnection;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Catalogue: features/connections/unsent_bytes_bound.feature
void main() {
  const int limit = 64 * 1024;
  const List<int> ping = <int>[0x89, 0x80, 1, 2, 3, 4];
  final List<HttpServer> servers = <HttpServer>[];
  final List<Socket> clients = <Socket>[];
  AtSecondaryContext? priorContext;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    priorContext = AtSecondaryServerImpl.getInstance().serverContext;
    AtSecondaryServerImpl.getInstance().serverContext = AtSecondaryContext()
      ..inboundMaxUnsentBytes = limit;
    atServer.inboundConnectionManager =
        InboundConnectionManager(serverAtSign: alice, poolSize: 10);
  });

  tearDown(() async {
    for (final Socket client in clients) {
      client.destroy();
    }
    clients.clear();
    for (final InboundConnection c
        in atServer.inboundConnectionManager.pool.getConnections().toList()) {
      await c.close();
    }
    for (final HttpServer server in servers) {
      await server.close(force: true);
    }
    servers.clear();
    AtSecondaryServerImpl.getInstance().serverContext = priorContext;
    await verbTestsTearDown();
  });

  /// A raw client of a WebSocket upgraded by
  /// [AtSecondaryServerImpl.routeHttpRequest], once it has read the 101 and
  /// the frame carrying the `@` prompt; [extraHeaders] go in the upgrade
  /// request.
  Future<_Client> connect({String extraHeaders = ''}) async {
    final HttpServer http =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(http);
    final AtServerHttpRequestHandler handler =
        AtServerHttpRequestHandler(alice, keyValueStore, enMgr);
    http.listen((HttpRequest r) => atServer.routeHttpRequest(r, handler));
    final Socket socket =
        await Socket.connect(InternetAddress.loopbackIPv4, http.port);
    clients.add(socket);
    final _Client client = _Client(socket);
    socket.write('GET /ws HTTP/1.1\r\n'
        'Host: 127.0.0.1:${http.port}\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        '$extraHeaders\r\n');
    final Stopwatch waited = Stopwatch()..start();
    while (client.firstFrame.length < 3 && waited.elapsed.inSeconds < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(client.firstFrame, hasLength(greaterThanOrEqualTo(3)),
        reason: 'precondition: the upgrade answered and the prompt arrived');
    return client;
  }

  InboundWebSocketConnection serverSide() =>
      atServer.inboundConnectionManager.pool.getConnections().single
          as InboundWebSocketConnection;

  group('Given a WebSocket monitor connection whose client has stopped reading',
      () {
    test(
        'when more than the limit is waiting, then the atServer destroys its socket at once and logs one warning',
        () async {
      final _Client client = await connect();
      client.subscription.pause();
      final InboundWebSocketConnection server = serverSide();
      server.metaData
        ..isAuthenticated = true
        ..authType = AuthType.apkam
        ..enrollmentId = 'e1';
      server.isMonitor = true;
      final Level priorLevel = server.logger.logger.level;
      server.logger.level = 'warning';
      final List<String> warnings = <String>[];
      final StreamSubscription<LogRecord> logs = server.logger.logger.onRecord
          .where((LogRecord r) => r.level == Level.WARNING)
          .listen((LogRecord r) => warnings.add(r.message));
      addTearDown(() async {
        await logs.cancel();
        server.logger.logger.level = priorLevel;
      });

      Object? refused;
      for (int i = 0; refused == null && i < 4000; i++) {
        try {
          await server.write('notification: {"id":"n$i",'
              '"value":"${'v' * 8192}"}\n');
        } on ConnectionInvalidException catch (e) {
          refused = e;
        }
        await Future<void>.delayed(Duration.zero);
      }
      expect(refused, isNotNull,
          reason: 'precondition: the limit closed the connection');

      Object? outcome;
      unawaited(client.socket.done.then(
          (_) => outcome ??= 'ended without an error',
          onError: (Object e) => outcome ??= e));
      for (int i = 0; outcome == null && i < 60; i++) {
        client.socket.add(ping);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(outcome, isA<SocketException>(),
          reason: 'a client that never read finds the atServer end of its '
              'connection gone when it next sends');
      expect(server.metaData.isClosed, isTrue);
      expect(
          warnings.single,
          allOf(
              contains('session ${server.metaData.sessionID} '
                  '(apkam, enrollment e1)'),
              contains('bytes would be waiting'),
              contains('over the limit of $limit')));
    });
  });

  group('Given a WebSocket connection that has been written to', () {
    test(
        'when the client sends a close frame and closes its socket, then the atServer closes the connection and its socket, and the connection leaves the pool',
        () async {
      final _Client client = await connect();
      final InboundWebSocketConnection server = serverSide();

      client.socket.add(<int>[0x88, 0x82, 1, 2, 3, 4, 0x03 ^ 1, 0xe8 ^ 2]);
      unawaited(client.socket.close());
      await client.ended.future.timeout(const Duration(seconds: 3),
          onTimeout: () => fail('the atServer did not close its socket'));
      final Stopwatch waited = Stopwatch()..start();
      while (atServer.inboundConnectionManager.pool.getCurrentSize() > 0 &&
          waited.elapsed.inSeconds < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(server.metaData.isClosed, isTrue);
      expect(atServer.inboundConnectionManager.pool.getCurrentSize(), 0);
    });
  });

  group('Given an upgrade request that repeats its Sec-WebSocket-Key', () {
    test('when it is sent, then it is answered 400', () async {
      final HttpServer http =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(http);
      final AtServerHttpRequestHandler handler =
          AtServerHttpRequestHandler(alice, keyValueStore, enMgr);
      http.listen((HttpRequest r) => atServer.routeHttpRequest(r, handler));
      final Socket socket =
          await Socket.connect(InternetAddress.loopbackIPv4, http.port);
      clients.add(socket);
      final _Client client = _Client(socket);

      socket.write('GET /ws HTTP/1.1\r\n'
          'Host: 127.0.0.1:${http.port}\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n');
      final Stopwatch waited = Stopwatch()..start();
      while (client._headersEnd < 0 && waited.elapsed.inSeconds < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(client.headers, startsWith('HTTP/1.1 400'),
          reason: 'the request is answered, and refused');
    });
  });

  group('Given a client that offers compression and a subprotocol', () {
    test('when it upgrades, then it gets neither and its frames are sent whole',
        () async {
      final _Client client = await connect(
          extraHeaders: 'Sec-WebSocket-Extensions: permessage-deflate;'
              ' client_max_window_bits\r\n'
              'Sec-WebSocket-Protocol: atProtocol\r\n');

      final String headers = client.headers.toLowerCase();
      expect(headers, startsWith('http/1.1 101'));
      expect(headers, isNot(contains('sec-websocket-extensions')));
      expect(headers, isNot(contains('sec-websocket-protocol')));
      expect(client.firstFrame.sublist(0, 3), [0x81, 0x01, 0x40],
          reason: 'one text frame carrying @, with no compression bit');
    });
  });
}

/// A raw socket that upgraded to a WebSocket, and what it has read.
class _Client {
  _Client(this.socket) {
    subscription =
        socket.listen(_read.addAll, onError: (Object _) {}, onDone: () {
      if (!ended.isCompleted) {
        ended.complete();
      }
    });
  }

  final Socket socket;
  final List<int> _read = <int>[];
  final Completer<void> ended = Completer<void>();
  late final StreamSubscription<Uint8List> subscription;

  int get _headersEnd =>
      latin1.decode(_read, allowInvalid: true).indexOf('\r\n\r\n');

  /// The upgrade response's status line and headers.
  String get headers {
    final int end = _headersEnd;
    return end < 0 ? '' : latin1.decode(_read.sublist(0, end));
  }

  /// The bytes read after the upgrade response.
  List<int> get firstFrame {
    final int end = _headersEnd;
    return end < 0 ? const <int>[] : _read.sublist(end + 4);
  }
}
