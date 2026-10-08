import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

/// An atServer serves HTTP on its atProtocol port only to a client that
/// negotiates ALPN `http/1.1`; any other connection speaks the atProtocol.
void main() {
  final String host =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  final int port =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];
  const String request = 'GET /publickey HTTP/1.1\r\nHost: atserver\r\n\r\n';

  test(
      'an HTTP request without ALPN is told ALPN http/1.1 is required, '
      'and the connection is closed', () async {
    final SecureSocket socket = await SecureSocket.connect(host, port);
    final StringBuffer received = StringBuffer();
    final Completer<void> closed = Completer<void>();
    void markClosed() => closed.isCompleted ? null : closed.complete();
    socket.listen((bytes) => received.write(utf8.decode(bytes)),
        onDone: markClosed, onError: (_) => markClosed());
    socket.write(request);

    await closed.future.timeout(const Duration(seconds: 10),
        onTimeout: () => fail('the atServer left the connection open; '
            'received: $received'));
    expect(received.toString(),
        '@error:AT0003-Exception: HTTP requests must negotiate ALPN http/1.1\n@');
    socket.destroy();
  });

  test('control: the same request with ALPN http/1.1 gets an HTTP response',
      () async {
    final HttpClient client = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) =>
          SecureSocket.startConnect(uri.host, uri.port,
              supportedProtocols: ['http/1.1']);
    try {
      final HttpClientResponse response = await (await client
              .getUrl(Uri.parse('https://$host:$port/publickey')))
          .close();
      await response.drain<void>();
      expect(response.statusCode, anyOf(HttpStatus.ok, HttpStatus.notFound));
    } finally {
      client.close();
    }
  });
}
