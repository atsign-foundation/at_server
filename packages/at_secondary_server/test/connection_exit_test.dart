import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

class MockWebSocket extends Mock implements WebSocket {}

/// A [FakeInboundConnection] that, like the real one, is marked closed once
/// it is closed, so that nothing arriving after the close is handled.
class ClosingConnection extends FakeInboundConnection {
  ClosingConnection(super.socket, super.metadata);

  @override
  Future<void> close() async {
    await super.close();
    metaData.isClosed = true;
  }
}

/// Catalogue: features/connection/exit.feature
void main() {
  setUpAll(() {
    verbTestsSetUpLogging();
    registerFallbackValue(const Stream<dynamic>.empty());
  });

  late FakeInboundConnection connection;
  late MockInboundConnectionPool pool;
  late List<String> dispatched;

  /// Listens on a connection with [metadata], recording the commands the
  /// listener dispatches.
  void listenOn(InboundConnectionMetadata metadata) {
    AtSecondaryServerImpl.getInstance().currentAtSign = '@alice'.toAtsign();
    connection = ClosingConnection(FakeSocket(), metadata);
    final manager = MockInboundConnectionManager();
    pool = MockInboundConnectionPool();
    when(() => manager.pool).thenReturn(pool);
    when(() => pool.remove(connection)).thenReturn(null);
    AtSecondaryServerImpl.getInstance().inboundConnectionManager = manager;

    dispatched = <String>[];
    InboundMessageListener(connection).listen(
        (String command, InboundConnection c) async => dispatched.add(command));
  }

  /// Returns once the connection is closed or written to, or after two
  /// seconds.
  Future<void> settle() async {
    final deadline = DateTime.now().add(Duration(seconds: 2));
    while (connection.closeCount == 0 &&
        connection.writes.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(milliseconds: 5));
    }
    // NOTE anything still queued behind the close or the write is dispatched
    // within this.
    await Future.delayed(Duration(milliseconds: 20));
  }

  /// Sends [flow] as one write on a new connection with [metadata], and
  /// returns once [settle] does.
  Future<void> send(InboundConnectionMetadata metadata, String flow) async {
    listenOn(metadata);
    connection.socket.addData(flow);
    await settle();
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
        verify(() => pool.remove(connection)).called(1);
        expect(dispatched, isEmpty,
            reason: '@exit is not a command for a verb handler');
      });
    }

    test('a client connected over a WebSocket', () async {
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
      var closed = false;
      when(() => ws.close()).thenAnswer((_) async {
        closed = true;
      });
      when(() => ws.readyState).thenReturn(WebSocket.open);
      final manager = MockInboundConnectionManager();
      pool = MockInboundConnectionPool();
      when(() => manager.pool).thenReturn(pool);
      AtSecondaryServerImpl.getInstance().inboundConnectionManager = manager;
      // NOTE a refusal's prompt reads this; without it no refusal is written,
      // whatever the atServer does with @exit.
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice'.toAtsign();

      final written = <dynamic>[];
      when(() => ws.addStream(any())).thenAnswer((invocation) {
        (invocation.positionalArguments[0] as Stream<dynamic>)
            .listen(written.add);
        return Completer<void>().future;
      });

      final wsConnection =
          InboundWebSocketConnection(ws, FakeSocket(), '123', null);
      when(() => pool.remove(wsConnection)).thenReturn(null);
      final wsDispatched = <String>[];
      wsConnection.acceptRequests((String command, InboundConnection c) async =>
          wsDispatched.add(command));
      incoming.add('@exit\n');
      final deadline = DateTime.now().add(Duration(seconds: 2));
      while (!closed && DateTime.now().isBefore(deadline)) {
        await Future.delayed(Duration(milliseconds: 5));
      }

      expect(written, isEmpty,
          reason: 'the atServer writes nothing in reply to @exit, but wrote '
              '$written');
      verifyNever(() => ws.add(any()));
      verify(() => ws.close()).called(1);
      verify(() => pool.remove(wsConnection)).called(1);
      expect(wsDispatched, isEmpty);
    });
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

  group('A command that starts with @exit is judged as the command it is', () {
    const String update = 'update:public:phone@alice 1';

    test('when it arrives in one write', () async {
      await send(InboundConnectionMetadata(), '@exit $update\n');
      expect(dispatched, isEmpty, reason: 'the update is not handled');
      expect(connection.writes, hasLength(1));
      expect(connection.writes.single, startsWith('error:AT0003'),
          reason: '"@exit $update" is an unknown verb');
      expect(connection.closeCount, 1,
          reason: 'a connection that has not authenticated is closed');
    });

    test('when its first 16 bytes arrive before the rest', () async {
      listenOn(InboundConnectionMetadata());
      // NOTE 16 bytes, so the head is judged before the rest arrives.
      connection.socket.addData('@exit${' ' * 11}');
      await settle();
      expect(connection.writes, hasLength(1),
          reason: 'the head is judged before the rest is sent');
      connection.socket.addData('$update\n');
      await settle();
      expect(dispatched, isEmpty, reason: 'the update is not handled');
      expect(connection.writes, hasLength(1));
      expect(connection.writes.single, startsWith('error:AT0003'),
          reason: 'the head is answered as an unknown verb');
      expect(connection.closeCount, 1,
          reason: 'a connection that has not authenticated is closed');
    });

    test('the validator passes only the whole command @exit', () {
      final unauthenticated =
          FakeInboundConnection(FakeSocket(), InboundConnectionMetadata());
      expect(
          () => InboundCommandValidator.validate(
              utf8.encode('@exit').toList(), unauthenticated),
          returnsNormally,
          reason: 'control: the command itself passes');
      for (final command in [
        '@exit:x',
        '@exit $update',
        '@exit${' ' * 251}$update',
        'update:public:phone@alice @exit',
      ]) {
        expect(
            () => InboundCommandValidator.validate(
                utf8.encode(command).toList(), unauthenticated),
            throwsA(anyOf(isA<InvalidSyntaxException>(),
                isA<UnAuthenticatedException>())),
            reason:
                '"${command.length > 40 ? '${command.substring(0, 40)}…' : command}" '
                'is not @exit and must be judged as itself');
      }
    });
  });
}
