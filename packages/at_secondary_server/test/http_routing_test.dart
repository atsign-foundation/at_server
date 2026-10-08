import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/http_request_handler.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  verbTestsSetUpLogging();
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  /// Serves [AtSecondaryServerImpl.routeHttpRequest] on loopback, GETs
  /// [path], and returns the status code with every error that escaped the
  /// zone the server ran in.
  Future<(int, List<Object>)> get(String path) async {
    final handler = AtServerHttpRequestHandler(alice, keyValueStore, enMgr);
    final List<Object> uncaught = [];
    final HttpServer server =
        await runZonedGuarded<Future<HttpServer>>(() async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((req) =>
          AtSecondaryServerImpl.getInstance().routeHttpRequest(req, handler));
      return s;
    }, (e, _) => uncaught.add(e))!;
    addTearDown(() => server.close(force: true));

    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientResponse response =
        await (await client.get('127.0.0.1', server.port, path)).close();
    await response.drain<void>();
    await Future.delayed(const Duration(milliseconds: 100));
    return (response.statusCode, uncaught);
  }

  test('a /ws request that is not a WebSocket upgrade is answered 400',
      () async {
    final (int status, List<Object> uncaught) = await get('/ws');
    expect(status, HttpStatus.badRequest);
    expect(uncaught, isEmpty,
        reason: 'an error escaping the request handling reaches the zone '
            'the atServer runs in');
  });

  test('control: any other path goes to the key handler', () async {
    final (int status, List<Object> uncaught) = await get('/nope');
    expect(status, HttpStatus.notFound);
    expect(uncaught, isEmpty);
  });
}
