import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart' show ConnectionInvalidException;
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
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
}
