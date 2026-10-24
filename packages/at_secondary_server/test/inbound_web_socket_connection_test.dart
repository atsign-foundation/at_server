import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart' show ConnectionInvalidException;
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockWebSocket extends Mock implements WebSocket {}

void main() {
  setUpAll(() => registerFallbackValue(const Stream<dynamic>.empty()));

  test('SENT is logged with its control characters escaped', () async {
    final ws = MockWebSocket();
    when(() => ws.done).thenAnswer((_) => Completer<void>().future);
    final written = <dynamic>[];
    when(() => ws.addStream(any())).thenAnswer((invocation) {
      (invocation.positionalArguments[0] as Stream<dynamic>)
          .listen(written.add);
      return Completer<void>().future;
    });
    final connection = InboundWebSocketConnection(ws, '123', null);
    final Level prior = connection.logger.logger.level;
    connection.logger.level = 'info';
    final records = <LogRecord>[];
    final sub = connection.logger.logger.onRecord.listen(records.add);
    try {
      await connection.write('error:AT0015-key not found : k\r\x1b[2J\n@');
    } finally {
      await sub.cancel();
      connection.logger.logger.level = prior;
    }
    expect(written, ['error:AT0015-key not found : k\r\x1b[2J\n@']);
    final sent = records.singleWhere((r) => r.message.contains('SENT: '));
    expect(sent.message,
        contains(r'SENT: error:AT0015-key not found : k\r\x1b[2J\n@'));
    expect(sent.message, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
  });

  group('Given a WebSocket connection', () {
    late MockWebSocket ws;
    late List<dynamic> written;
    late Completer<void> transport;

    setUp(() {
      ws = MockWebSocket();
      when(() => ws.done).thenAnswer((_) => Completer<void>().future);
      when(() => ws.close()).thenAnswer((_) async {});
      written = <dynamic>[];
      transport = Completer<void>();
      when(() => ws.addStream(any())).thenAnswer((invocation) {
        (invocation.positionalArguments[0] as Stream<dynamic>)
            .listen(written.add);
        return transport.future;
      });
    });

    test('when it is written to, then its last access time moves on', () async {
      final connection = InboundWebSocketConnection(ws, '123', null);
      final DateTime before =
          DateTime.timestamp().subtract(const Duration(seconds: 1));
      connection.metaData.lastAccessed = before;

      await connection.write('data:first\n@');

      expect(connection.metaData.lastAccessed!.isAfter(before), isTrue);
    });

    test('when it is written to after it closed, then the write is refused',
        () async {
      final connection = InboundWebSocketConnection(ws, '123', null);
      await connection.write('data:first\n@');
      await connection.close();

      await expectLater(connection.write('data:second\n@'),
          throwsA(isA<ConnectionInvalidException>()));
      expect(written, ['data:first\n@']);
    });

    test(
        'when its WebSocket stops taking writes, then later writes are refused',
        () async {
      final connection = InboundWebSocketConnection(ws, '123', null);
      await connection.write('data:first\n@');

      transport.completeError(const SocketException('connection reset'));
      await Future<void>.delayed(Duration.zero);

      expect(connection.isInValid(), isTrue);
      await expectLater(connection.write('data:second\n@'),
          throwsA(isA<ConnectionInvalidException>()));
    });
  });

  group('Given a WebSocket connection whose client has stopped reading', () {
    test(
        'when a write would take the UTF-8 bytes waiting above the limit, then the connection closes with one warning and the write is refused',
        () async {
      final AtSecondaryContext? prior =
          AtSecondaryServerImpl.getInstance().serverContext;
      AtSecondaryServerImpl.getInstance().serverContext = AtSecondaryContext()
        ..inboundMaxUnsentBytes = 10;
      addTearDown(
          () => AtSecondaryServerImpl.getInstance().serverContext = prior);
      final ws = MockWebSocket();
      when(() => ws.done).thenAnswer((_) => Completer<void>().future);
      when(() => ws.close()).thenAnswer((_) async {});
      when(() => ws.addStream(any())).thenAnswer((invocation) {
        (invocation.positionalArguments[0] as Stream<dynamic>)
            .listen((_) {})
            .pause();
        return Completer<void>().future;
      });
      final connection = InboundWebSocketConnection(ws, '123', null);
      final Level priorLevel = connection.logger.logger.level;
      connection.logger.level = 'warning';
      final warnings = <String>[];
      final sub = connection.logger.logger.onRecord
          .where((r) => r.level == Level.WARNING)
          .listen((r) => warnings.add(r.message));
      addTearDown(() async {
        await sub.cancel();
        connection.logger.logger.level = priorLevel;
      });

      await connection.write('\u00e9\u00e9\u00e9\u00e9');
      expect(connection.unsentBytes, 8, reason: 'four two-byte characters');
      await expectLater(connection.write('\u00e9\u00e9'),
          throwsA(isA<ConnectionInvalidException>()));

      expect(connection.metaData.isClosed, isTrue);
      expect(
          warnings.single,
          allOf(
              contains('12 bytes would be waiting'), contains('limit of 10')));
    });
  });

  group('Given a real WebSocket connection that has been written to', () {
    test(
        'when its client sends a close frame, then the connection closes without waiting on the listener',
        () async {
      final HttpServer http =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      final Future<WebSocket> upgraded =
          http.first.then((HttpRequest r) => WebSocketTransformer.upgrade(r));
      final Socket client =
          await Socket.connect(InternetAddress.loopbackIPv4, http.port);
      addTearDown(client.destroy);
      client.listen((_) {}, onError: (_) {});
      client.write('GET / HTTP/1.1\r\n'
          'Host: 127.0.0.1:${http.port}\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n');
      final WebSocket ws = await upgraded;
      final connection = InboundWebSocketConnection(ws, 'closing', null);
      ws.listen((_) {}, onError: (_) {});
      await connection.write('@');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      client.add(<int>[0x88, 0x82, 1, 2, 3, 4, 0x03 ^ 1, 0xe8 ^ 2]);
      await client.flush();
      final Stopwatch waited = Stopwatch()..start();
      while (!connection.metaData.isClosed && waited.elapsed.inSeconds < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(connection.metaData.isClosed, isTrue);
    });
  });
}
