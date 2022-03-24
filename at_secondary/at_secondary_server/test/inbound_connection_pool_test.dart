import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

var serverContext = AtSecondaryContext();

void main() async {
  setUpAll(() {
    serverContext.inboundIdleTimeMillis = 1000;
    serverContext.inboundConnectionLowWaterMarkRatio = 0.5;
    serverContext.unauthenticatedMinAllowableIdleTimeMillis = 20;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
    InboundConnectionPool.getInstance().init(10);
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
      poolInstance.init(10);
      Socket? dummySocket;
      var connection1 = MockInBoundConnectionImpl(dummySocket, 'aaa');
      var connection2 = MockInBoundConnectionImpl(dummySocket, 'bbb');
      var connection3 = MockInBoundConnectionImpl(dummySocket, 'ccc');
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      poolInstance.add(connection3);
      sleep(Duration(milliseconds: (serverContext.inboundIdleTimeMillis * 0.9).floor()));
      connection2.write('test data');
      expect(poolInstance.getCurrentSize(), 3);
      sleep(Duration(milliseconds: (serverContext.inboundIdleTimeMillis * 0.2).floor()));
      print('connection 1: ${connection1.getMetaData().created} '
          '${connection1.getMetaData().lastAccessed} ${connection1.isInValid()}');
      print('connection 2: ${connection2.getMetaData().created} '
          '${connection2.getMetaData().lastAccessed} ${connection2.isInValid()}');
      print('connection 3: ${connection3.getMetaData().created} '
          '${connection3.getMetaData().lastAccessed} ${connection3.isInValid()}');
      poolInstance.clearInvalidConnections();
      expect(poolInstance.getCurrentSize(), 1);
    });

    /// Verify that, at lowWaterMark, allowable idle time is still as configured by inboundIdleTimeMillis
    test('test connection pool - at lowWaterMark - clear idle connection', () {
      int maxPoolSize = 10;

      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(maxPoolSize);
      var connections = [];

      int lowWaterMark = (maxPoolSize * serverContext.inboundConnectionLowWaterMarkRatio).floor();
      for (int i = 0; i < lowWaterMark; i++) {
        var mockConnection = MockInBoundConnectionImpl(null, 'mock session $i');
        connections.add(mockConnection);
        poolInstance.add(mockConnection);
      }

      sleep(Duration(milliseconds: (serverContext.inboundIdleTimeMillis * 0.9).floor()));

      connections[1].write('test data');
      expect(poolInstance.getCurrentSize(), lowWaterMark);
      sleep(Duration(milliseconds: ((serverContext.inboundIdleTimeMillis * 0.1) + 1).floor()));

      poolInstance.clearInvalidConnections();
      expect(poolInstance.getCurrentSize(), 1);
    });

    /// Verify that, beyond lowWaterMark, allowable idle time progressively reduces
    test('test connection pool - 90% capacity - clear idle connection', () {
      int maxPoolSize = 100; // Please don't change this

      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(maxPoolSize);
      var connections = [];

      int desiredPoolSize = (maxPoolSize * 0.9).floor();
      int numAuthenticated = 0;
      int numUnauthenticated = 0;
      for (int i = 0; i < desiredPoolSize; i++) {
        var mockConnection = MockInBoundConnectionImpl(null, 'mock session $i');
        if (i.isEven) {
          mockConnection.getMetaData().isAuthenticated = true;
          numAuthenticated++;
        } else {
          numUnauthenticated++;
        }
        connections.add(mockConnection);
        poolInstance.add(mockConnection);
      }


      int unauthenticatedMinAllowableIdleTimeMillis = serverContext.unauthenticatedMinAllowableIdleTimeMillis;
      int authenticatedMinAllowableIdleTimeMillis = (serverContext.inboundIdleTimeMillis / 5).floor();

      // Actual allowable idle time should be as per InboundConnectionImpl.dart - i.e.
      int unauthenticatedActualAllowableIdleTime = calcActualAllowableIdleTime(poolInstance, maxPoolSize, unauthenticatedMinAllowableIdleTimeMillis);

      print ("unAuth actual allowed: $unauthenticatedActualAllowableIdleTime");

      int now = DateTime.now().millisecondsSinceEpoch;
      int startTime = now;

      // Before simulating activity, let's first sleep for 90% of the currently allowable idle time for UNAUTHENTICATED connections
      sleep(Duration(milliseconds: (unauthenticatedActualAllowableIdleTime * 0.9).floor()));

      int numAuthToWriteTo = 3;
      int numUnAuthToWriteTo = 10;
      // Let's write to a few authenticated connections, and some more unauthenticated connections
      for (int i = 0; i < numAuthToWriteTo; i++) {
        connections[i*2].write('test data'); // evens are authenticated
      }
      for (int i = 0; i < numUnAuthToWriteTo; i++) {
        connections[i*2+1].write('test data'); // odds are not authenticated
      }

      // pool size should be as expected before checking invalidity
      expect(poolInstance.getCurrentSize(), desiredPoolSize);
      poolInstance.clearInvalidConnections();
      // no invalid connections should have yet been cleared
      expect(poolInstance.getCurrentSize(), desiredPoolSize);

      // now let's sleep until the unused connections will have been idle for longer than the currently allowable idle time for UNAUTHENTICATED connections
      sleep(Duration(milliseconds: ((unauthenticatedActualAllowableIdleTime * 0.1) + 1).floor()));
      // now when we clear invalid connections, we're going to see all of the unused unauthenticated connections returned to pool
      // Since we wrote to 10 unauthenticated connections, that means we will clean up numUnauthenticated - 10
      poolInstance.clearInvalidConnections();
      int expected = desiredPoolSize - (numUnauthenticated - numUnAuthToWriteTo);
      now = DateTime.now().millisecondsSinceEpoch;
      int elapsed = now - startTime;
      print ('After $elapsed : expect pool size after unauthenticated clean up to be $expected (pre-clear size was $desiredPoolSize)');
      expect(poolInstance.getCurrentSize(), expected);

      // now let's sleep until the unused connections will have been idle for longer than the currently allowable idle time for AUTHENTICATED connections
      int authenticatedActualAllowableIdleTime = calcActualAllowableIdleTime(poolInstance, maxPoolSize, authenticatedMinAllowableIdleTimeMillis);
      print ("auth actual allowed: $authenticatedActualAllowableIdleTime");
      sleep(Duration(milliseconds: authenticatedActualAllowableIdleTime - elapsed + 1));
      // now when we clear invalid connections, we're going to additionally see all of the unused AUTHENTICATED connections returned to pool
      // Since we wrote to 3 authenticated connections, that means we will clean up an additional numAuthenticated - 3 connections
      poolInstance.clearInvalidConnections();
      expected -= (numAuthenticated - numAuthToWriteTo);
      now = DateTime.now().millisecondsSinceEpoch;
      elapsed = now-startTime;
      print ('After $elapsed : expect pool size after AUTHenticated clean up to be $expected (pre-clear size was $desiredPoolSize)');
      expect(poolInstance.getCurrentSize(), expected);

    });
  });
}

int calcActualAllowableIdleTime(poolInstance, maxPoolSize, minAllowableIdleTime) {
  int lowWaterMark = (maxPoolSize * serverContext.inboundConnectionLowWaterMarkRatio).floor();
  int numConnectionsOverLwm = max(poolInstance.getCurrentSize() - lowWaterMark, 0);
  double idleTimeReductionFactor = 1 - (numConnectionsOverLwm / (maxPoolSize - lowWaterMark));
  return
  (((serverContext.inboundIdleTimeMillis - minAllowableIdleTime) * idleTimeReductionFactor) +
      minAllowableIdleTime)
      .floor();
}

class MockInBoundConnectionImpl extends InboundConnectionImpl {
  MockInBoundConnectionImpl(Socket? socket, String sessionId)
      : super(socket, sessionId, owningPool: InboundConnectionPool.getInstance());

  @override
  Future<void> close() async {
    getMetaData().isClosed = true;
  }

  @override
  void write(String data) {
    getMetaData().lastAccessed = DateTime.now().toUtc();
  }
}
