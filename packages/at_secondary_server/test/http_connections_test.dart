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

import 'test_utils.dart';

/// The virtual environment's certificate, already in the repo.
const String _certificates =
    '../../tools/build_virtual_environment/ve_base/contents/atsign/root/certs';

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

  /// Starts @alice's atServer on a free port, holding at most [httpMaxLimit]
  /// HTTP connections, in a zone that records what reaches it, as the
  /// bootstrapper's does.
  Future<void> serve({required int httpMaxLimit}) async {
    final SecurityContext context = SecurityContext()
      ..useCertificateChain('$_certificates/fullchain.pem')
      ..usePrivateKey('$_certificates/privkey.pem')
      ..setAlpnProtocols(['atProtocol/1.0', 'http/1.1'], true);
    final Completer<void> ready = Completer();
    unawaited(runZonedGuarded(() async {
      serverSocket = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, context);
      http = AtSecondaryServerImpl.getInstance()
          .listenOn(serverSocket, httpMaxLimit: httpMaxLimit);
      ready.complete();
    }, (Object e, StackTrace _) => uncaught.add(e)));
    await ready.future;
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
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');
    expect((await client.get('/hello')).status, 200);

    await client.closed.future.timeout(Duration(seconds: 11),
        onTimeout: () => fail('the connection is open 11 s after its answer'));
  }, timeout: Timeout(Duration(seconds: 30)));

  test(
      'An HTTP connection that sends no complete request is closed within 10 '
      'seconds', () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');

    client.socket.write('GET /hel');
    await client.socket.flush();

    await client.closed.future.timeout(Duration(seconds: 11),
        onTimeout: () => fail('the connection is open 11 s after part of a '
            'request'));
  }, timeout: Timeout(Duration(seconds: 30)));

  test('An HTTP connection beyond the limit is closed without an answer',
      () async {
    expect(AtSecondaryConfig.http_max_limit, 50, reason: 'the default');
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final List<_Client> held =
        await Future.wait([for (int i = 0; i < 50; i++) connect('http/1.1')]);
    await Future.delayed(Duration(milliseconds: 300));

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

  test('A WebSocket at /ws is not closed by the HTTP idle timeout', () async {
    await serve(httpMaxLimit: AtSecondaryConfig.http_max_limit);
    final _Client client = await connect('http/1.1');
    client.socket.write('GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n');
    await client.until((String text) => text.startsWith('HTTP/1.1 101'),
        reason: 'the connection upgrades to a WebSocket');

    await Future.delayed(Duration(seconds: 15));

    expect(client.closed.isCompleted, isFalse,
        reason: 'the WebSocket is open after 15 s');
  }, timeout: Timeout(Duration(seconds: 40)));

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

  test('An HTTP request the atServer cannot answer is answered 500', () async {
    final _Store store = _Store();
    when(() => store.get(any())).thenAnswer((_) async => _UnreadableData());
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
    runZonedGuarded(
        () => unawaited(AtSecondaryServerImpl.getInstance()
            .acceptSocket(_FailingSocket(), http)),
        (Object e, StackTrace _) => uncaught.add(e));
    await Future.delayed(Duration(milliseconds: 100));
    await sub.cancel();
    expect(uncaught, isEmpty,
        reason: 'nothing reaches the zone the atServer runs in');
    expect(logged.map((r) => r.message).join('\n'), contains('injected'),
        reason: 'the HTTP server raised the error');

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
    await Future.delayed(Duration(milliseconds: 300));
    final _Client again = await connect('http/1.1');
    expect((await again.get('/hello')).status, 200);
    await refused();
    await sub.cancel();

    expect(warnings, hasLength(2), reason: 'a second after one was held');
  });
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
  Future<_Answer> get(String path) async {
    final int from = received.length;
    socket.write('GET $path HTTP/1.1\r\nHost: x\r\n\r\n');
    await socket.flush();
    await until((String text) => _Answer.tryParse(text.substring(from)) != null,
        reason: 'GET $path is answered');
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

  @override
  InternetAddress get address => throw StateError('injected');

  @override
  void destroy() {}
}
