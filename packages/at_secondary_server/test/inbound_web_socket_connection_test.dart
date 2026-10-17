import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

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

  test('@exit over a WebSocket closes it with nothing written', () async {
    final ws = MockWebSocket();
    final incoming = StreamController<dynamic>();
    addTearDown(incoming.close);
    when(() => ws.done).thenAnswer((_) => Completer<void>().future);
    when(() => ws.listen(any(),
            onError: any(named: 'onError'),
            onDone: any(named: 'onDone'),
            cancelOnError: any(named: 'cancelOnError')))
        .thenAnswer((invocation) => incoming.stream.listen(
            invocation.positionalArguments[0] as void Function(dynamic),
            onError: invocation.namedArguments[#onError] as Function?,
            onDone: invocation.namedArguments[#onDone] as void Function()?));
    when(() => ws.close()).thenAnswer((_) async {});
    when(() => ws.readyState).thenReturn(WebSocket.open);
    final manager = MockInboundConnectionManager();
    final pool = MockInboundConnectionPool();
    when(() => manager.pool).thenReturn(pool);
    AtSecondaryServerImpl.getInstance().inboundConnectionManager = manager;
    // A refusal's prompt reads this, so without it a refusal is never written.
    AtSecondaryServerImpl.getInstance().currentAtSign = '@alice'.toAtsign();

    final connection = InboundWebSocketConnection(ws, '123', null);
    when(() => pool.remove(connection)).thenReturn(null);
    final dispatched = <String>[];
    connection.acceptRequests(
        (String command, InboundConnection c) async => dispatched.add(command),
        (List<int> data, InboundConnection c) {});
    incoming.add('@exit\n');
    await Future.delayed(Duration(milliseconds: 60));

    verify(() => ws.close()).called(1);
    verifyNever(() => ws.add(any()));
    expect(dispatched, isEmpty);
  });
}
