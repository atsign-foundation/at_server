import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

void main() async {
  var testIdleTimeMillis = 250;
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.inboundIdleTimeMillis = testIdleTimeMillis;
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
      Socket? dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      var connection2 = InboundConnectionImpl(dummySocket, 'bbb');
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);
    });
    test('test connection pool has capacity', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(2);
      Socket? dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      poolInstance.add(connection1);
      expect(poolInstance.hasCapacity(), true);
    });

    test('test connection pool has no capacity', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(2);
      Socket? dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      var connection2 = InboundConnectionImpl(dummySocket, 'bbb');
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      expect(poolInstance.hasCapacity(), false);
    });

    test('test connection pool - clear closed connection', () {
      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(2);
      Socket? dummySocket;
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
      Socket? dummySocket;
      var connection1 = MockInBoundConnectionImpl(dummySocket, 'aaa');
      var connection2 = MockInBoundConnectionImpl(dummySocket, 'bbb');
      var connection3 = MockInBoundConnectionImpl(dummySocket, 'ccc');
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      poolInstance.add(connection3);

      // Wait for 90 percent of the idle time to pass, then write to one of the connections
      sleep(Duration(milliseconds: (testIdleTimeMillis * 0.9).round()));
      connection2.write('test data');
      expect(poolInstance.getCurrentSize(), 3);

      // Now wait for the other 10 percent of the idle time to pass, plus 1 millisecond
      // Two of the connections should now have passed their idle time, will be invalid, and will be cleared by clearInvalidConnections
      sleep(Duration(milliseconds: (testIdleTimeMillis * 0.1).round() + 1));
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
