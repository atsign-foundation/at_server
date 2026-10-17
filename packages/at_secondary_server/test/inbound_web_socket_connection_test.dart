import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockWebSocket extends Mock implements WebSocket {}

void main() {
  test('SENT is logged with its control characters escaped', () async {
    final ws = MockWebSocket();
    when(() => ws.done).thenAnswer((_) => Completer<void>().future);
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
    verify(() => ws.add('error:AT0015-key not found : k\r\x1b[2J\n@'));
    final sent = records.singleWhere((r) => r.message.contains('SENT: '));
    expect(sent.message,
        contains(r'SENT: error:AT0015-key not found : k\r\x1b[2J\n@'));
    expect(sent.message, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
  });
}
