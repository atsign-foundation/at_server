import 'dart:io';

import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

void main() async {
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.inboundIdleTimeMillis = 10000;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
  });
  tearDown(() {
    InboundConnectionPool.getInstance().clearAllConnections();
  });
  group('A group of inbound connection pool test', () {
    test('test connection pool init', () {
      InboundConnectionPool.getInstance().init((5));
      expect(InboundConnectionPool.getInstance().getCapacity(), 5);
      expect(InboundConnectionPool.getInstance().getCurrentSize(), 0);
    });

    test('test connection pool add connections', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(5);
      var connection1 = DummyInboundConnection.getInstance();
      var connection2 = DummyInboundConnection.getInstance();
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);
    });

    test('test connection pool has capacity', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(2);
      var connection1 = DummyInboundConnection.getInstance();
      poolInstance.add(connection1);
      expect(poolInstance.hasCapacity(), true);
    });

    test('test connection pool has no capacity', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(2);
      var connection1 = DummyInboundConnection.getInstance();
      var connection2 = DummyInboundConnection.getInstance();
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      expect(poolInstance.hasCapacity(), false);
    });

    test('test connection pool - clear closed connection', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(2);
      var dummySocket;
      var connection1 = MockInBoundConnectionImpl(dummySocket, 'aaa');
      var connection2 = MockInBoundConnectionImpl(dummySocket, 'bbb');
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      expect(poolInstance.getCurrentSize(), 2);
      connection1.close();
      poolInstance.clearInvalidConnections();
      expect(poolInstance.getCurrentSize(), 1);
    });

    test('test connection pool - clear idle connection', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(2);
      var dummySocket;
      var connection1 = MockInBoundConnectionImpl(dummySocket, 'aaa');
      var connection2 = MockInBoundConnectionImpl(dummySocket, 'bbb');
      var connection3 = MockInBoundConnectionImpl(dummySocket, 'ccc');
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      poolInstance.add(connection3);
      sleep(Duration(seconds: 9));
      connection2.write('test data');
      expect(poolInstance.getCurrentSize(), 3);
      sleep(Duration(seconds: 2));
      print('connection 1: ${connection1.getMetaData().created} '
          '${connection1.getMetaData().lastAccessed} ${connection1.isInValid()}');
      print('connection 2: ${connection2.getMetaData().created} '
          '${connection2.getMetaData().lastAccessed} ${connection2.isInValid()}');
      print('connection 3: ${connection3.getMetaData().created} '
          '${connection3.getMetaData().lastAccessed} ${connection3.isInValid()}');
      poolInstance.clearInvalidConnections();
      expect(poolInstance.getCurrentSize(), 1);
    });
  });
}

class MockInBoundConnectionImpl extends InboundConnectionImpl {
  MockInBoundConnectionImpl(Socket? socket, String sessionId)
      : super(socket, sessionId);

  @override
  Future<void> close() async {
    print('closing mock connection');
    getMetaData().isClosed = true;
  }

  @override
  void write(String data) {
    print('writing to mock connection');
    getMetaData().lastAccessed = DateTime.now().toUtc();
  }
}
