import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_root_server/src/directory_lookup.dart';
import 'package:at_root_server/src/server/at_root_server_impl.dart';
import 'package:at_root_server/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart' show PseudoServerSocket;
import 'package:test/test.dart';

/// Catalogue: features/directory/alpn_http.feature
void main() {
  const Map<String, String> records = {
    'alice': 'alice.example:6464',
    '🦄': 'unicorn.example:6464',
  };

  group('Given an atDirectory with TLS', () {
    late RootServerImpl directory;
    late int tlsPort;
    late int httpsPort;

    setUpAll(() async {
      tlsPort = await _freePort();
      httpsPort = await _freePort();
      directory =
          _directory(records, port: tlsPort, httpsPort: httpsPort, useSSL: true)
            ..start();
      await _accepting(tlsPort);
      await _accepting(httpsPort);
    });

    tearDownAll(() async => await directory.stop());

    group(
        'A client that does not negotiate http/1.1 speaks the Atsign Protocol',
        () {
      for (final (String offer, List<String>? protocols, String? selected) in [
        ('no ALPN', null, null),
        ('atProtocol/1.0', ['atProtocol/1.0'], 'atProtocol/1.0'),
        (
          'atProtocol/1.0, http/1.1',
          ['atProtocol/1.0', 'http/1.1'],
          'atProtocol/1.0'
        ),
        ('h2', ['h2'], null),
      ]) {
        test('offering $offer', () async {
          final SecureSocket socket = await _tls(tlsPort, protocols);

          expect(socket.selectedProtocol, selected);
          expect(
              await _atProtocolLookup(socket, 'alice'), 'alice.example:6464');
          socket.destroy();
        });
      }
    });

    group('A client that negotiates http/1.1 is answered over HTTP', () {
      for (final (List<String> offer, String path, int status, String expect_)
          in [
        (['http/1.1'], '/@alice', 200, 'body alice.example:6464'),
        (['h2', 'http/1.1'], '/@alice', 200, 'body alice.example:6464'),
        (
          ['http/1.1'],
          '/@alice/x/y?z=1',
          302,
          'location https://alice.example:6464/@alice/x/y?z=1'
        ),
        (
          ['http/1.1'],
          '/@alice/a%0D%0A%3F%23',
          302,
          'location https://alice.example:6464/@alice/a%0D%0A%3F%23'
        ),
        (['http/1.1'], '/@nobody', 404, ''),
        (['http/1.1'], '/@', 404, ''),
        (['http/1.1'], '/@a!b', 404, ''),
        (['http/1.1'], '/@alice/', 200, 'body alice.example:6464'),
        (['http/1.1'], '/%ff', 400, ''),
        (['http/1.1'], '/@alice/${'a' * 993}', 400, ''),
      ]) {
        test(
            'offering ${offer.join(', ')}, GET '
            '${path.length > 40 ? 'a path of ${path.length} characters' : path}',
            () async {
          final SecureSocket socket = await _tls(tlsPort, offer);
          expect(socket.selectedProtocol, 'http/1.1');

          final _Answer answer = await _http(socket, 'GET $path');

          expect(answer.status, status, reason: answer.raw);
          if (expect_.startsWith('body ')) {
            expect(answer.body, expect_.substring('body '.length));
          }
          if (expect_.startsWith('location ')) {
            expect(answer.headers['location'],
                expect_.substring('location '.length));
          }
        });
      }
    });

    group('Any origin may read an HTTP answer', () {
      for (final (String port, String method, String path, int status) in [
        ('its TLS port, negotiating http/1.1', 'GET', '/@alice', 200),
        ('its TLS port, negotiating http/1.1', 'GET', '/@nobody', 404),
        ('its HTTPS port', 'GET', '/@alice', 200),
        ('its HTTPS port', 'POST', '/@alice', 401),
      ]) {
        test('$port, $method $path', () async {
          final SecureSocket socket = port.startsWith('its TLS')
              ? await _tls(tlsPort, ['http/1.1'])
              : await _tls(httpsPort, null);

          final _Answer answer = await _http(socket, '$method $path',
              headers: 'Origin: https://finder.example\r\n');

          expect(answer.status, status, reason: answer.raw);
          expect(answer.headers['access-control-allow-origin'], '*');
        });
      }
    });

    group('An HTTP connection is closed once its response is sent', () {
      for (final String port in [
        'its TLS port, negotiating http/1.1',
        'its HTTPS port',
      ]) {
        test(port, () async {
          final SecureSocket socket = port.startsWith('its TLS')
              ? await _tls(tlsPort, ['http/1.1'])
              : await _tls(httpsPort, null);
          const String request = 'GET /@alice HTTP/1.1\r\nHost: x\r\n'
              'Connection: keep-alive\r\n\r\n';

          final _Read read = await _readUntilClosed(socket,
              send: '$request$request', within: Duration(seconds: 3));

          expect(read.closed, isTrue,
              reason: 'the atDirectory closes the connection');
          expect('HTTP/1.1 '.allMatches(read.text).length, 1,
              reason: 'it is answered once: ${read.text}');
          final _Answer answer = _Answer.parse(read.text);
          expect(answer.status, 200);
          expect(answer.body, 'alice.example:6464');
          expect(answer.headers['connection'], 'close');
        });
      }
    });

    group(
        'An HTTP connection that sends no complete request is closed within '
        '10 seconds', () {
      for (final (String port, String sent, String bytes) in [
        ('its TLS port, negotiating http/1.1', 'nothing', ''),
        (
          'its TLS port, negotiating http/1.1',
          "half of a request's header",
          'GET /@alice HTTP/1.1\r\nHo'
        ),
        ('its HTTPS port', 'nothing', ''),
      ]) {
        test('$port, sending $sent', () async {
          final SecureSocket socket = port.startsWith('its TLS')
              ? await _tls(tlsPort, ['http/1.1'])
              : await _tls(httpsPort, null);

          final _Read read = await _readUntilClosed(socket,
              send: bytes, within: Duration(seconds: 15));

          expect(read.closed, isTrue);
          expect(read.text, isEmpty, reason: 'it is closed without an answer');
          // NOTE the idle timer fires at twice the 5-second timeout; one more
          // second allows for scheduling.
          expect(read.took, lessThan(Duration(seconds: 11)));
        }, timeout: Timeout(Duration(seconds: 30)));
      }
    });

    test(
        'when an HTTP request names an atSign in another spelling, then it '
        'is looked up, and redirected, in canonical form', () async {
      final _Answer record =
          await _http(await _tls(tlsPort, ['http/1.1']), 'GET /@Ali.ce');
      final _Answer redirect =
          await _http(await _tls(tlsPort, ['http/1.1']), 'GET /@Alice/x');

      expect(record.status, 200, reason: record.raw);
      expect(record.body, 'alice.example:6464');
      expect(
          redirect.headers['location'], 'https://alice.example:6464/@alice/x');
    });

    test('An HTTP request the atDirectory cannot answer is answered 500',
        () async {
      final saved = directory.lookup;
      directory.lookup = (String _) async => throw Exception('unreadable');
      try {
        final _Answer answer =
            await _http(await _tls(tlsPort, ['http/1.1']), 'GET /@alice');

        expect(answer.status, 500, reason: answer.raw);
        expect(answer.headers['connection'], 'close');
      } finally {
        directory.lookup = saved;
      }
    });

    test(
        'when a redirect names an atSign outside ASCII, then the atSign is '
        'percent-encoded in its Location', () async {
      final _Answer answer = await _http(
          await _tls(tlsPort, ['http/1.1']), 'GET /@%F0%9F%A6%84/x');

      expect(answer.status, 302, reason: answer.raw);
      expect(answer.headers['location'],
          'https://unicorn.example:6464/@%F0%9F%A6%84/x');
    });

    test(
        'when an Atsign Protocol lookup names no atSign, or not a valid one, '
        'then it is answered null', () async {
      for (final String name in ['', 'a!b']) {
        final SecureSocket socket = await _tls(tlsPort, null);

        expect(await _atProtocolLookup(socket, name), 'null',
            reason: 'looking up "$name"');
        socket.destroy();
      }
    });

    test(
        'when an Atsign Protocol lookup names an atSign in another spelling, '
        'then it is looked up in canonical form', () async {
      final SecureSocket socket = await _tls(tlsPort, null);

      expect(await _atProtocolLookup(socket, 'Ali.ce'), 'alice.example:6464');
      socket.destroy();
    });

    test('The HTTPS port answers HTTP whatever ALPN the client offers',
        () async {
      for (final List<String>? offer in [
        null,
        ['atProtocol/1.0'],
        ['http/1.1'],
        ['h2', 'http/1.1'],
      ]) {
        final SecureSocket socket = await _tls(httpsPort, offer);
        expect(socket.selectedProtocol, isNull, reason: 'offering $offer');

        final _Answer answer = await _http(socket, 'GET /@alice');

        expect(answer.status, 200, reason: 'offering $offer: ${answer.raw}');
        expect(answer.body, 'alice.example:6464');
      }
    });
  });

  test(
      'Given an atDirectory with an Atsign Protocol client connected, when '
      'it stops, then its port refuses new connections, and the client is '
      'disconnected', () async {
    final int port = await _freePort();
    final RootServerImpl directory =
        _directory(records, port: port, httpsPort: 0, useSSL: false)..start();
    await _accepting(port);
    final Socket client =
        await Socket.connect(InternetAddress.loopbackIPv4, port);
    final Completer<void> disconnected = Completer();
    client.listen((_) {},
        onDone: () => disconnected.isCompleted ? null : disconnected.complete(),
        onError: (_) =>
            disconnected.isCompleted ? null : disconnected.complete());
    await Future.delayed(Duration(milliseconds: 100));

    await directory.stop();

    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()));
    await disconnected.future.timeout(Duration(seconds: 3),
        onTimeout: () => fail('the connected client is not disconnected'));
    client.destroy();
  });

  test(
      'Given a connection that negotiated http/1.1, when the HTTP server '
      'fails as it takes the connection, then the error does not escape',
      () async {
    final RootServerImpl directory = RootServerImpl();
    final PseudoServerSocket httpSockets =
        directory.serveHttpOn(_FakeSecureServerSocket());
    final List<Object> uncaught = [];

    runZonedGuarded(() => directory.acceptSocket(_FailingSocket(), httpSockets),
        (Object e, _) => uncaught.add(e));
    await Future.delayed(Duration(milliseconds: 100));

    expect(uncaught, isEmpty);
    await RootServerImpl.alpnHttpServer!.close(force: true);
    RootServerImpl.alpnHttpServer = null;
  });

  group('Given an atDirectory whose every uncaught error is recorded', () {
    late RootServerImpl directory;
    late int tlsPort;
    late int httpsPort;
    final List<Object> uncaught = [];

    setUpAll(() async {
      tlsPort = await _freePort();
      httpsPort = await _freePort();
      runZonedGuarded(() {
        directory = _directory(records,
            port: tlsPort, httpsPort: httpsPort, useSSL: true)
          ..start();
      }, (Object e, _) => uncaught.add(e));
      await _accepting(tlsPort);
      await _accepting(httpsPort);
    });

    tearDownAll(() async => await directory.stop());

    group('The atDirectory keeps answering when a connection fails', () {
      for (final (String port, String fails) in [
        ('its HTTPS port', 'resets the connection before sending anything'),
        (
          'its HTTPS port',
          'resets the connection partway through its TLS hello'
        ),
        ('its TLS port', 'resets the connection before sending anything'),
        (
          'its HTTPS port',
          'sends GET /@alice and resets the connection before its answer'
        ),
      ]) {
        test('$port, $fails', () async {
          uncaught.clear();
          final int target = port == 'its TLS port' ? tlsPort : httpsPort;

          if (fails.startsWith('sends GET')) {
            final saved = directory.lookup;
            directory.lookup = (String atSign) async {
              await Future.delayed(Duration(milliseconds: 400));
              return records[atSign];
            };
            final SecureSocket socket = await _tls(target, null);
            socket.write('GET /@alice HTTP/1.1\r\nHost: x\r\n\r\n');
            await socket.flush();
            await Future.delayed(Duration(milliseconds: 50));
            socket.setRawOption(_lingerZero);
            socket.destroy();
            await Future.delayed(Duration(milliseconds: 1000));
            directory.lookup = saved;
          } else {
            await _reset(target,
                send: fails.contains('TLS hello') ? _halfClientHello : []);
            await Future.delayed(Duration(milliseconds: 500));
          }

          expect(uncaught, isEmpty, reason: 'the atDirectory keeps running');
          // NOTE the port whose connection failed is the one probed; the TLS
          // port answers HTTP once http/1.1 is negotiated.
          final _Answer answer = await _http(
              await _tls(target, target == tlsPort ? ['http/1.1'] : null),
              'GET /@alice');
          expect(answer.status, 200, reason: answer.raw);
        });
      }
    });
  });

  group('Given a name the atDirectory is asked for', () {
    for (final (String name, String? key) in [
      ('alice', 'alice'),
      ('@alice', 'alice'),
      ('Ali.ce', 'alice'),
      ('', null),
      ('a!b', null),
    ]) {
      test('when it is "$name", then its key is $key', () {
        expect(directoryKeyOf(name), key);
      });
    }
  });

  group('Given an atDirectory without TLS', () {
    late RootServerImpl directory;
    late int port;

    setUpAll(() async {
      port = await _freePort();
      directory = _directory(records, port: port, httpsPort: 0, useSSL: false)
        ..start();
      await _accepting(port);
    });

    tearDownAll(() async => await directory.stop());

    test('An atDirectory run without TLS speaks only the Atsign Protocol',
        () async {
      final Socket socket =
          await Socket.connect(InternetAddress.loopbackIPv4, port);

      expect(await _atProtocolLookup(socket, 'alice'), 'alice.example:6464');
      socket.destroy();
    });
  });
}

/// The virtual environment's atDirectory certificate, already in the repo.
const String _certificates =
    '../../tools/build_virtual_environment/ve_base/contents/atsign/root/certs';

RootServerImpl _directory(Map<String, String> records,
    {required int port, required int httpsPort, required bool useSSL}) {
  final AtRootServerContext context = AtRootServerContext()
    ..port = port
    ..httpsPort = httpsPort
    ..httpsEnabled = useSSL
    ..redisServerHost = 'unused'
    ..redisServerPort = 0
    ..redisAuth = 'unused'
    ..useSSL = useSSL
    ..securityContext = useSSL ? _TestSecurityContext() : null;
  return RootServerImpl()
    ..lookup = ((String atSign) async => records[atSign])
    ..setServerContext(context);
}

class _TestSecurityContext implements AtSecurityContext {
  @override
  String publicKeyPath() => '$_certificates/fullchain.pem';

  @override
  String privateKeyPath() => '$_certificates/privkey.pem';

  @override
  String trustedCertificatePath() => throw UnimplementedError();

  @override
  String bundle() => throw UnimplementedError();
}

/// The first bytes of a TLS ClientHello, stopping partway through it.
const List<int> _halfClientHello = [
  0x16, 0x03, 0x01, 0x00, 0xa0, 0x01, 0x00, 0x00, 0x9c, 0x03, 0x03 //
];

/// Connects to [port], sends [send], then resets the connection.
Future<void> _reset(int port, {required List<int> send}) async {
  final RawSocket socket =
      await RawSocket.connect(InternetAddress.loopbackIPv4, port);
  socket.listen((RawSocketEvent event) {
    if (event == RawSocketEvent.read) socket.read();
  }, onError: (_) {});
  if (send.isNotEmpty) socket.write(send);
  await Future.delayed(Duration(milliseconds: 200));
  socket.setRawOption(_lingerZero);
  await socket.close();
}

/// An SO_LINGER of zero, which makes a socket's close a reset.
final RawSocketOption _lingerZero = RawSocketOption(
    RawSocketOption.levelSocket,
    Platform.isMacOS ? 0x0080 : 13,
    Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0]));

Future<int> _freePort() async {
  final ServerSocket socket =
      await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final int port = socket.port;
  await socket.close();
  return port;
}

/// Waits until [port] accepts a connection, failing after 10 seconds.
Future<void> _accepting(int port) async {
  final DateTime deadline = DateTime.now().add(Duration(seconds: 10));
  while (true) {
    try {
      (await Socket.connect(InternetAddress.loopbackIPv4, port)).destroy();
      return;
    } on SocketException {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future.delayed(Duration(milliseconds: 50));
    }
  }
}

Future<SecureSocket> _tls(int port, List<String>? protocols) =>
    SecureSocket.connect(InternetAddress.loopbackIPv4, port,
        supportedProtocols: protocols, onBadCertificate: (_) => true);

/// Sends [atSign] over the Atsign Protocol on [socket] and returns the
/// answer.
Future<String> _atProtocolLookup(Socket socket, String atSign) async {
  final StringBuffer received = StringBuffer();
  final Completer<String> answered = Completer();
  bool asked = false;
  socket.listen((List<int> data) {
    received.write(utf8.decode(data));
    final String text = received.toString();
    if (!asked && text.startsWith('@')) {
      asked = true;
      received.clear();
      socket.write('$atSign\n');
    } else if (asked && text.endsWith('\r\n@') && !answered.isCompleted) {
      answered.complete(text.substring(0, text.length - '\r\n@'.length));
    }
  });
  return answered.future.timeout(Duration(seconds: 5));
}

class _Read {
  final String text;
  final bool closed;
  final Duration took;

  _Read(this.text, this.closed, this.took);
}

/// Sends [send] on [socket], then reads until the server closes it or
/// [within] passes.
Future<_Read> _readUntilClosed(Socket socket,
    {required String send, required Duration within}) async {
  final Stopwatch clock = Stopwatch()..start();
  final StringBuffer received = StringBuffer();
  final Completer<void> closed = Completer();
  socket.listen((List<int> data) => received.write(utf8.decode(data)),
      onDone: () => closed.complete(),
      onError: (_) => closed.isCompleted ? null : closed.complete());
  if (send.isNotEmpty) socket.write(send);
  await closed.future.timeout(within, onTimeout: () {});
  final _Read read =
      _Read(received.toString(), closed.isCompleted, clock.elapsed);
  socket.destroy();
  return read;
}

class _Answer {
  final int status;
  final Map<String, String> headers;
  final String body;
  final String raw;

  _Answer(this.status, this.headers, this.body, this.raw);

  factory _Answer.parse(String raw) {
    final int end = raw.indexOf('\r\n\r\n');
    final List<String> head =
        (end < 0 ? raw : raw.substring(0, end)).split('\r\n');
    final Map<String, String> headers = {
      for (final String line in head.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase():
              line.substring(line.indexOf(':') + 1).trim()
    };
    String body = end < 0 ? '' : raw.substring(end + 4);
    if (headers['transfer-encoding'] == 'chunked') {
      body = _unchunked(body);
    }
    return _Answer(int.parse(head.first.split(' ')[1]), headers, body, raw);
  }

  /// [chunked], an HTTP/1.1 chunked body, as the bytes its chunks carry.
  static String _unchunked(String chunked) {
    final StringBuffer body = StringBuffer();
    int at = 0;
    while (true) {
      final int lineEnd = chunked.indexOf('\r\n', at);
      final int size = int.parse(chunked.substring(at, lineEnd), radix: 16);
      if (size == 0) return body.toString();
      body.write(chunked.substring(lineEnd + 2, lineEnd + 2 + size));
      at = lineEnd + 2 + size + 2;
    }
  }
}

/// Sends one HTTP/1.1 [requestLine] with [headers] on [socket] and returns
/// the answer.
Future<_Answer> _http(SecureSocket socket, String requestLine,
    {String headers = ''}) async {
  final _Read read = await _readUntilClosed(socket,
      send: '$requestLine HTTP/1.1\r\nHost: x\r\n$headers\r\n',
      within: Duration(seconds: 5));
  return _Answer.parse(read.text);
}

class _FakeSecureServerSocket implements SecureServerSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A socket that negotiated http/1.1 and fails as the HTTP server sets it up.
class _FailingSocket implements SecureSocket {
  @override
  String? get selectedProtocol => 'http/1.1';

  @override
  bool setOption(SocketOption option, bool enabled) =>
      throw const SocketException('setsockopt failed');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
