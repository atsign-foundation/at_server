import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/http_connections.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'test_utils.dart';

/// The virtual environment's certificate, already in the repo.
const String _certificates =
    '../../tools/build_virtual_environment/ve_base/contents/atsign/root/certs';

/// The idle timeout and answer deadline the timing tests serve with.
const Duration _shortIdle = Duration(milliseconds: 500);
const Duration _shortDeadline = Duration(milliseconds: 500);

/// Catalogue: features/http/http_connections.feature
void main() {
  late SecureServerSocket serverSocket;
  late HttpConnections http;
  final List<_Client> clients = [];
  final List<Object> uncaught = [];

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    HttpConnections.logger.level = 'warning';
    uncaught.clear();
    clients.clear();
    await keyValueStore.put('public:hello$alice', AtData()..data = 'hello');
  });

  tearDown(() async {
    for (final _Client client in clients) {
      client.socket.destroy();
    }
    await http.close();
    await serverSocket.close();
    await verbTestsTearDown();
  });

  SecurityContext tlsContext() => SecurityContext()
    ..useCertificateChain('$_certificates/fullchain.pem')
    ..usePrivateKey('$_certificates/privkey.pem')
    ..setAlpnProtocols(['atProtocol/1.0', 'http/1.1'], true);

  /// Starts @alice's atServer on a free port, holding at most [httpMaxLimit]
  /// HTTP connections, in a zone that records what reaches it, as the
  /// bootstrapper's does. Without [idleTimeout] or [answerDeadline] it
  /// listens with its defaults.
  Future<void> serve(
      {required int httpMaxLimit,
      Duration? idleTimeout,
      Duration? answerDeadline}) async {
    final Completer<void> ready = Completer();
    unawaited(runZonedGuarded(() async {
      serverSocket = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, tlsContext());
      final AtSecondaryServerImpl atServer =
          AtSecondaryServerImpl.getInstance();
      http = idleTimeout == null && answerDeadline == null
          ? atServer.listenOn(serverSocket, httpMaxLimit: httpMaxLimit)
          : atServer.listenOn(serverSocket,
              httpMaxLimit: httpMaxLimit,
              idleTimeout: idleTimeout ?? HttpConnections.defaultIdleTimeout,
              answerDeadline:
                  answerDeadline ?? HttpConnections.defaultAnswerDeadline);
      ready.complete();
    }, (Object e, StackTrace _) => uncaught.add(e)));
    await ready.future;
  }

  /// Starts an HTTP side on a free port that answers each request with
  /// [onRequest], waiting [answerDeadline] for an answer.
  Future<void> serveStandIn(void Function(HttpRequest request) onRequest,
      {required Duration answerDeadline}) async {
    serverSocket = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, tlsContext());
    http = HttpConnections.serve(serverSocket,
        maxConnections: 50,
        idleTimeout: HttpConnections.defaultIdleTimeout,
        answerDeadline: answerDeadline,
        onRequest: onRequest);
    serverSocket.listen(http.add);
  }

  /// Waits up to 5 seconds for the atServer to hold [count] HTTP connections.
  Future<void> untilHeld(int count) async {
    final Stopwatch waited = Stopwatch()..start();
    while (http.held != count) {
      if (waited.elapsed > Duration(seconds: 5)) {
        fail('the atServer holds ${http.held} HTTP connections, not $count');
      }
      await Future.delayed(Duration(milliseconds: 10));
    }
  }

  Future<_Client> connect(String protocol) async {
    final _Client client = await _Client.connect(serverSocket.port, protocol);
    clients.add(client);
    return client;
  }

  /// Expects a client that negotiates atProtocol/1.0 to get the atServer's
  /// prompt.
  Future<void> expectAtProtocolServed() async {
    final _Client client = await connect('atProtocol/1.0');
    await client.until((String text) => text.startsWith('@'),
        reason: 'an Atsign Protocol client is served');
  }

  test('An HTTP connection carries a further request', () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');

    final _Answer first = await client.get('/hello');
    final _Answer second = await client.get('/hello');

    expect([first.status, first.body], [200, 'hello'], reason: first.raw);
    expect([second.status, second.body], [200, 'hello'], reason: second.raw);
  });

  test('An idle HTTP connection is closed within 10 seconds', () async {
    await serve(
        httpMaxLimit: AtSecondaryConfig.http_max_limit,
        idleTimeout: _shortIdle);
    final _Client client = await connect('http/1.1');
    expect((await client.get('/hello')).status, 200);

    await client.closed.future.timeout(_shortIdle * 3,
        onTimeout: () => fail('the connection is open past twice the idle '
            'timeout after its answer'));
  });

  test(
      'An HTTP connection that sends no complete request is closed within 10 '
      'seconds', () async {
    await serve(
        httpMaxLimit: AtSecondaryConfig.http_max_limit,
        idleTimeout: _shortIdle);
    final _Client client = await connect('http/1.1');

    client.socket.write('GET /hel');
    await client.socket.flush();

    await client.closed.future.timeout(_shortIdle * 3,
        onTimeout: () => fail('the connection is open past twice the idle '
            'timeout after part of a request'));
  });

  test('An HTTP connection beyond the limit is closed without an answer',
      () async {
    expect(AtSecondaryConfig.http_max_limit, 50, reason: 'the default');
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final List<_Client> held =
        await Future.wait([for (int i = 0; i < 50; i++) connect('http/1.1')]);
    await untilHeld(50);

    final _Client beyond = await connect('http/1.1');
    beyond.socket.write('GET /hello HTTP/1.1\r\nHost: x\r\n\r\n');

    await beyond.closed.future.timeout(Duration(seconds: 3),
        onTimeout: () => fail('the connection beyond the limit is open'));
    expect(beyond.received, isEmpty, reason: 'it is closed unanswered');
    expect([
      for (final _Client c in held)
        if (c.closed.isCompleted) c
    ], isEmpty, reason: 'the held connections are still open');
    final List<_Answer> answers =
        await Future.wait([for (final _Client c in held) c.get('/hello')]);
    expect({for (final _Answer a in answers) a.status}, {200});
    await expectAtProtocolServed();
  });

  group(
      'An atServer started with connection.http_max_limit <limit> closes HTTP '
      'connections beyond it', () {
    for (final int limit in [0, 2]) {
      test('limit $limit', () async {
        final YamlMap? saved = AtSecondaryConfig.configYamlMap;
        addTearDown(() => AtSecondaryConfig.configYamlMap = saved);
        AtSecondaryConfig.configYamlMap =
            loadYaml('connection:\n  http_max_limit: $limit') as YamlMap;
        final (SecureServerSocket socket, HttpConnections connections) =
            await AtSecondaryServerImpl.getInstance()
                .bindAndListen(tlsContext(), await _freePort());
        serverSocket = socket;
        http = connections;
        final List<_Client> held = await Future.wait(
            [for (int i = 0; i < limit; i++) connect('http/1.1')]);
        await untilHeld(limit);

        final _Client beyond = await connect('http/1.1');

        await beyond.closed.future.timeout(Duration(seconds: 3),
            onTimeout: () =>
                fail('a connection beyond $limit is open at startup'));
        expect(beyond.received, isEmpty, reason: 'it is closed unanswered');
        expect([
          for (final _Client c in held)
            if (c.closed.isCompleted) c
        ], isEmpty, reason: 'the held connections are still open');
      });
    }
  });

  test('An atServer whose http_max_limit is 0 holds no HTTP connection',
      () async {
    await serve(httpMaxLimit: 0);
    final _Client client = await connect('http/1.1');
    client.socket.write('GET /hello HTTP/1.1\r\nHost: x\r\n\r\n');

    await client.closed.future.timeout(Duration(seconds: 3),
        onTimeout: () => fail('the HTTP connection is open'));
    expect(client.received, isEmpty, reason: 'it is closed unanswered');
    await expectAtProtocolServed();
  });

  /// An answer the client does not read stays in progress, as an answer this
  /// stand-in never finishes does.
  test(
      'An HTTP connection whose answer is not sent within 30 seconds is '
      'closed', () async {
    await serveStandIn((HttpRequest request) {},
        answerDeadline: _shortDeadline);
    final _Client client = await connect('http/1.1');

    client.socket.write('GET /hello HTTP/1.1\r\nHost: x\r\n\r\n');

    await client.closed.future.timeout(_shortDeadline * 3,
        onTimeout: () => fail('the connection is open past the answer '
            'deadline'));
    expect(client.received, isEmpty, reason: 'nothing was answered');
  });

  test(
      'Given an answer sent in time, when the answer deadline passes, then its '
      'connection stays open', () async {
    await serveStandIn((HttpRequest request) {
      request.response.write('hello');
      unawaited(request.response.close());
    }, answerDeadline: _shortDeadline);
    final _Client client = await connect('http/1.1');
    expect((await client.get('/hello')).body, 'hello');

    await Future.delayed(_shortDeadline * 3);

    expect(client.closed.isCompleted, isFalse,
        reason: 'an answered connection is held until it is idle');
  });

  test(
      'A WebSocket at /ws is not closed by the HTTP idle timeout or answer '
      'deadline', () async {
    await serve(
        httpMaxLimit: AtSecondaryConfig.http_max_limit,
        idleTimeout: _shortIdle,
        answerDeadline: _shortDeadline);
    final _Client client = await connect('http/1.1');
    client.socket.write('GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n');
    await client.until((String text) => text.startsWith('HTTP/1.1 101'),
        reason: 'the connection upgrades to a WebSocket');

    await Future.delayed(_shortIdle * 4);

    expect(client.closed.isCompleted, isFalse,
        reason: 'the WebSocket is open past both');
  });

  test(
      'Given HTTP connections are held, when the HTTP side is closed, then '
      'each is closed', () async {
    final Completer<void> requested = Completer();
    await serveStandIn((HttpRequest request) => requested.complete(),
        answerDeadline: HttpConnections.defaultAnswerDeadline);
    final _Client idle = await connect('http/1.1');
    final _Client busy = await connect('http/1.1');
    busy.socket.write('GET /hello HTTP/1.1\r\nHost: x\r\n\r\n');
    await requested.future.timeout(Duration(seconds: 3));
    await untilHeld(2);

    await http.close();

    for (final (String which, _Client client) in [
      ('the idle connection', idle),
      ('the connection with a request in progress', busy)
    ]) {
      await client.closed.future.timeout(Duration(seconds: 3),
          onTimeout: () => fail('$which is open after close'));
    }
  });

  test(
      'Given an atServer listening as it starts, when its HTTP side is built, '
      'then it holds an idle connection for 5 seconds and an answer for 30',
      () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);

    expect(http.idleTimeout, Duration(seconds: 5));
    expect(http.answerDeadline, Duration(seconds: 30));
  });

  test('An HTTP request whose path does not decode is answered 400', () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');

    final _Answer answer = await client.get('/%ff');

    expect(answer.status, 400, reason: answer.raw);
  });

  test(
      'Given an HTTP request, when its query does not decode, then it is '
      'answered 400', () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');

    final _Answer answer = await client.get('/hello?x=%ff');

    expect(answer.status, 400, reason: answer.raw);
  });

  test(
      'Given a request that is not a GET, when its path does not decode, then '
      'it is answered 405', () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');

    final _Answer answer = await client.send('POST', '/%ff');

    expect(answer.status, 405, reason: answer.raw);
  });

  test('An HTTP request the atServer cannot answer is answered 500', () async {
    final _Store store = _Store();
    when(() => store.get(any())).thenAnswer((_) async => _UnreadableData());
    AtSecondaryServerImpl.getInstance().keyValueStore = store;
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');

    final _Answer answer = await client.get('/hello');

    expect(answer.status, 500, reason: answer.raw);
  });

  test(
      'Given the keystore fails reading the record, when a client sends GET '
      '/hello, then it is answered 500', () async {
    final _Store store = _Store();
    when(() => store.get(any())).thenThrow(DataStoreException('injected'));
    AtSecondaryServerImpl.getInstance().keyValueStore = store;
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');

    final _Answer answer = await client.get('/hello');

    expect(answer.status, 500, reason: answer.raw);
  });

  test('An error the HTTP server raises does not stop the atServer', () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final List<LogRecord> logged = [];
    final StreamSubscription<LogRecord> sub =
        HttpConnections.logger.logger.onRecord.listen(logged.add);
    final _FailingSocket failing = _FailingSocket();
    runZonedGuarded(
        () => unawaited(
            AtSecondaryServerImpl.getInstance().acceptSocket(failing, http)),
        (Object e, StackTrace _) => uncaught.add(e));
    await Future.delayed(Duration(milliseconds: 100));
    await sub.cancel();
    expect(uncaught, isEmpty,
        reason: 'nothing reaches the zone the atServer runs in');
    expect(logged.map((r) => r.message).join('\n'), contains('injected'),
        reason: 'the HTTP server raised the error');
    expect(failing.destroyed, isTrue,
        reason: 'the connection the error concerns is closed');

    final _Client client = await connect('http/1.1');
    final _Answer answer = await client.get('/hello');

    expect([answer.status, answer.body], [200, 'hello'], reason: answer.raw);
    await expectAtProtocolServed();
    expect(uncaught, isEmpty, reason: 'nothing reaches it later either');
  });

  test(
      'Given the HTTP connection limit is reached, when further connections '
      'are refused, then one warning is logged until a connection is held '
      'again', () async {
    await serve(httpMaxLimit: 1);
    final List<LogRecord> warnings = [];
    final StreamSubscription<LogRecord> sub = HttpConnections
        .logger.logger.onRecord
        .where((LogRecord r) => r.level == Level.WARNING)
        .listen(warnings.add);
    Future<_Client> refused() async {
      final _Client client = await connect('http/1.1');
      await client.closed.future.timeout(Duration(seconds: 3),
          onTimeout: () => fail('a connection beyond the limit is open'));
      return client;
    }

    final _Client held = await connect('http/1.1');
    expect((await held.get('/hello')).status, 200);
    await refused();
    await refused();
    expect(warnings, hasLength(1), reason: 'one warning for the first two');

    held.socket.destroy();
    await untilHeld(0);
    final _Client again = await connect('http/1.1');
    expect((await again.get('/hello')).status, 200);
    await refused();
    await sub.cancel();

    expect(warnings, hasLength(2), reason: 'a second after one was held');
  });
}

/// A port nothing listens on now.
Future<int> _freePort() async {
  final ServerSocket socket =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final int port = socket.port;
  await socket.close();
  return port;
}

/// A client connection that negotiated a protocol by ALPN.
class _Client {
  final SecureSocket socket;
  final StringBuffer _received = StringBuffer();

  /// Completes when the atServer closes the connection.
  final Completer<void> closed = Completer();

  _Client(this.socket) {
    socket.listen((List<int> data) => _received.write(latin1.decode(data)),
        onDone: _close, onError: (_) => _close());
    // NOTE a write to a connection the atServer has closed fails here, not on
    // the stream above.
    unawaited(socket.done.then((_) {}, onError: (_) => _close()));
  }

  static Future<_Client> connect(int port, String protocol) async =>
      _Client(await SecureSocket.connect(InternetAddress.loopbackIPv4, port,
          supportedProtocols: [protocol], onBadCertificate: (_) => true));

  String get received => _received.toString();

  void _close() {
    if (!closed.isCompleted) {
      closed.complete();
    }
  }

  /// Waits up to 5 seconds for what has been received to satisfy [done].
  Future<void> until(bool Function(String text) done,
      {required String reason}) async {
    final Stopwatch waited = Stopwatch()..start();
    while (!done(received)) {
      if (waited.elapsed > Duration(seconds: 5) || closed.isCompleted) {
        fail('$reason; received: $received');
      }
      await Future.delayed(Duration(milliseconds: 20));
    }
  }

  /// Sends GET [path] and returns its answer.
  Future<_Answer> get(String path) => send('GET', path);

  /// Sends a [method] request, with no body, for [path] and returns its
  /// answer.
  Future<_Answer> send(String method, String path) async {
    final int from = received.length;
    socket.write('$method $path HTTP/1.1\r\nHost: x\r\n'
        'Content-Length: 0\r\n\r\n');
    await socket.flush();
    await until((String text) => _Answer.tryParse(text.substring(from)) != null,
        reason: '$method $path is answered');
    return _Answer.tryParse(received.substring(from))!;
  }
}

/// An HTTP/1.1 response.
class _Answer {
  final int status;
  final String body;
  final String raw;

  _Answer(this.status, this.body, this.raw);

  /// The response [raw] begins with, or null until it is complete.
  static _Answer? tryParse(String raw) {
    final int end = raw.indexOf('\r\n\r\n');
    if (end < 0) {
      return null;
    }
    final List<String> head = raw.substring(0, end).split('\r\n');
    final Map<String, String> headers = {
      for (final String line in head.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase():
              line.substring(line.indexOf(':') + 1).trim()
    };
    final String rest = raw.substring(end + 4);
    final int status = int.parse(head.first.split(' ')[1]);
    if (headers['transfer-encoding'] == 'chunked') {
      final String? body = _unchunked(rest);
      return body == null ? null : _Answer(status, body, raw);
    }
    final int length = int.parse(headers['content-length'] ?? '0');
    return rest.length < length
        ? null
        : _Answer(status, rest.substring(0, length), raw);
  }

  /// The bytes [chunked]'s chunks carry, or null until its last chunk.
  static String? _unchunked(String chunked) {
    final StringBuffer body = StringBuffer();
    int at = 0;
    while (true) {
      final int lineEnd = chunked.indexOf('\r\n', at);
      if (lineEnd < 0) {
        return null;
      }
      final int size = int.parse(chunked.substring(at, lineEnd), radix: 16);
      if (size == 0) {
        return body.toString();
      }
      if (chunked.length < lineEnd + 2 + size + 2) {
        return null;
      }
      body.write(chunked.substring(lineEnd + 2, lineEnd + 2 + size));
      at = lineEnd + 2 + size + 2;
    }
  }
}

class _Store extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {}

/// A record whose value cannot be read.
class _UnreadableData extends AtData {
  @override
  String? get data => throw StateError('injected');
}

/// A socket that negotiated http/1.1 and fails as the HTTP server sets it up.
class _FailingSocket extends Fake implements SecureSocket {
  @override
  String? get selectedProtocol => 'http/1.1';

  bool destroyed = false;

  @override
  InternetAddress get address => throw StateError('injected');

  @override
  void destroy() => destroyed = true;
}
