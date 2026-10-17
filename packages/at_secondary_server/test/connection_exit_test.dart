import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Catalogue: features/connection/exit.feature
void main() {
  setUpAll(() {
    verbTestsSetUpLogging();
  });

  late FakeInboundConnection connection;
  late List<String> dispatched;

  /// Listens on a connection with [metadata], sends [flow] as one write,
  /// records the commands the listener dispatches, and returns once the
  /// connection is closed or written to, or after two seconds.
  Future<void> send(InboundConnectionMetadata metadata, String flow) async {
    AtSecondaryServerImpl.getInstance().currentAtSign = '@alice'.toAtsign();
    connection = FakeInboundConnection(FakeSocket(), metadata);
    final manager = MockInboundConnectionManager();
    final pool = MockInboundConnectionPool();
    when(() => manager.pool).thenReturn(pool);
    when(() => pool.remove(connection)).thenReturn(null);
    AtSecondaryServerImpl.getInstance().inboundConnectionManager = manager;

    dispatched = <String>[];
    InboundMessageListener(connection).listen(
        (String command, InboundConnection c) async => dispatched.add(command),
        (List<int> data, InboundConnection c) {});
    connection.socket.addData(flow);
    final deadline = DateTime.now().add(Duration(seconds: 2));
    while (connection.closeCount == 0 &&
        connection.writes.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(milliseconds: 5));
    }
    // Lets anything still queued behind the close or the write be dispatched.
    await Future.delayed(Duration(milliseconds: 20));
  }

  group('An atServer closes the connection on @exit', () {
    for (final (String example, InboundConnectionMetadata Function() md) in [
      (
        'a client that has not authenticated',
        () => InboundConnectionMetadata()
      ),
      (
        'a client authenticated as @alice',
        () => InboundConnectionMetadata()..isAuthenticated = true
      ),
      (
        'a peer atServer that has proved itself as @bob by pol',
        () => InboundConnectionMetadata()
          ..isPolAuthenticated = true
          ..fromAtSign = '@bob'.toAtsign()
      ),
    ]) {
      test(example, () async {
        await send(md(), '@exit\n');
        expect(connection.writes, isEmpty,
            reason: 'the atServer writes nothing in reply to @exit, but wrote '
                '${connection.writes}');
        expect(connection.closeCount, 1, reason: 'the connection is closed');
        expect(dispatched, isEmpty,
            reason: '@exit is not a command for a verb handler');
      });
    }
  });

  test('Commands before @exit are answered, and commands after it are not',
      () async {
    await send(InboundConnectionMetadata()..isAuthenticated = true,
        'noop:0\n@exit\nnoop:0\n');
    expect(dispatched, ['noop:0'],
        reason: 'the first noop:0 is handled and the second is not');
    expect(connection.closeCount, 1, reason: 'the connection is closed');
    expect(connection.writes, isEmpty,
        reason: 'nothing is written for @exit, and the handler stub writes '
            'nothing for noop:0');
  });

  test('A command that only resembles @exit is refused as before', () async {
    await send(InboundConnectionMetadata()..isAuthenticated = true, 'exit\n');
    expect(connection.writes, hasLength(1));
    expect(connection.writes.single, startsWith('error:AT0003'),
        reason: 'exit is an unknown verb');
    expect(connection.closeCount, 0, reason: 'the connection stays open');
    expect(dispatched, isEmpty);
  });
}
