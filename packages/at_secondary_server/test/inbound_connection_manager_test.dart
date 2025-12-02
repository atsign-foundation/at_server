import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  verbTestsSetUpLogging();

  late FakeSocket mockSocket;

  late InboundConnectionManager icm;

  setUp(() {
    atServer.serverContext = AtSecondaryContext()
      ..unauthenticatedInboundIdleTimeMillis = 10000;
    atServer.inboundConnectionManager = icm = InboundConnectionManager(
        serverAtSign: alice, poolSize: AtSecondaryConfig.inbound_max_limit);
    mockSocket = FakeSocket();
      });

  tearDown(() {
    atServer.inboundConnectionManager.close();
  });

  group('A group of inbound connection manager tests', () {
    test('test inbound connection manager - create connection ', () {
      icm.pool.resize(5);
      var createdConnection =
          icm.createSocketConnection(mockSocket, sessionId: 'aaa');
      expect(createdConnection.metaData.sessionID, 'aaa');
      expect(createdConnection.metaData.isCreated, true);
    });

    test('test inbound connection manager - current pool size', () {
      icm.pool.resize(2);
      icm.createSocketConnection(mockSocket, sessionId: 'aaa');
      expect(icm.pool.getActiveConnectionSize(), 1);
    });

    test('test inbound connection manager - current pool size no connections',
        () {
      expect(icm.pool.getActiveConnectionSize(), 0);
    });

    test('test inbound connection manager - connect limit test', () {
      icm.pool.resize(2);
      icm.createSocketConnection(mockSocket, sessionId: 'aaa');
      icm.createSocketConnection(mockSocket, sessionId: 'bbb');
      expect(
          () => icm.createSocketConnection(mockSocket, sessionId: 'ccc'),
          throwsA(predicate((dynamic e) =>
              e is InboundConnectionLimitException &&
              e.message == 'max limit reached on inbound pool')));
    });

    test('test inbound connection manager - has capacity true', () {
      icm.pool.resize(5);
      icm.createSocketConnection(mockSocket, sessionId: 'aaa');
      icm.createSocketConnection(mockSocket, sessionId: 'bbb');
      icm.createSocketConnection(mockSocket, sessionId: 'ccc');
      expect(icm.hasCapacity(), true);
    });

    test('test inbound connection manager - has capacity false', () {
      icm.pool.resize(3);
      icm.createSocketConnection(mockSocket, sessionId: 'aaa');
      icm.createSocketConnection(mockSocket, sessionId: 'bbb');
      icm.createSocketConnection(mockSocket, sessionId: 'ccc');
      expect(icm.hasCapacity(), false);
    });

    test('test inbound connection manager -clear connections', () {
      icm.pool.resize(3);
      icm.createSocketConnection(mockSocket, sessionId: 'aaa');
      icm.createSocketConnection(mockSocket, sessionId: 'bbb');
      icm.createSocketConnection(mockSocket, sessionId: 'ccc');
      icm.close();
      expect(icm.pool.getActiveConnectionSize(), 0);
    });
  });
}
