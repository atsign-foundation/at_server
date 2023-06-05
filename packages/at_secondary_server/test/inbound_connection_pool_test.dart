import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';
import 'package:at_utils/at_utils.dart';

var serverContext = AtSecondaryContext();

AtSignLogger logger = AtSignLogger('inbound_connection_pool_test');

void main() async {
  setUpAll(() {
    serverContext.unauthenticatedInboundIdleTimeMillis = 250;
    serverContext.authenticatedInboundIdleTimeMillis = 500;
    serverContext.inboundConnectionLowWaterMarkRatio = 0.5;
    serverContext.unauthenticatedMinAllowableIdleTimeMillis = 20;
    serverContext.authenticatedMinAllowableIdleTimeMillis = 100;
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
      var connection1 = MockInboundConnectionImpl(dummySocket, 'aaa');
      var connection2 = MockInboundConnectionImpl(dummySocket, 'bbb');
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
      var connection1 = MockInboundConnectionImpl(dummySocket, 'aaa');
      var connection2 = MockInboundConnectionImpl(dummySocket, 'bbb');
      var connection3 = MockInboundConnectionImpl(dummySocket, 'ccc');
      poolInstance.add(connection1);
      poolInstance.add(connection2);
      poolInstance.add(connection3);
      sleep(Duration(
          milliseconds:
              (serverContext.unauthenticatedInboundIdleTimeMillis * 0.9)
                  .floor()));
      connection2.write('test data');
      expect(poolInstance.getCurrentSize(), 3);
      sleep(Duration(
          milliseconds:
              (serverContext.unauthenticatedInboundIdleTimeMillis * 0.2)
                  .floor()));
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

      int lowWaterMark =
          (maxPoolSize * serverContext.inboundConnectionLowWaterMarkRatio)
              .floor();
      for (int i = 0; i < lowWaterMark; i++) {
        var mockConnection = MockInboundConnectionImpl(null, 'mock session $i');
        connections.add(mockConnection);
        poolInstance.add(mockConnection);
      }

      sleep(Duration(
          milliseconds:
              (serverContext.unauthenticatedInboundIdleTimeMillis * 0.9)
                  .floor()));

      connections[1].write('test data');
      expect(poolInstance.getCurrentSize(), lowWaterMark);
      sleep(Duration(
          milliseconds:
              ((serverContext.unauthenticatedInboundIdleTimeMillis * 0.1) + 1)
                  .floor()));

      poolInstance.clearInvalidConnections();
      expect(poolInstance.getCurrentSize(), 1);
    });

    /// Verify that, beyond lowWaterMark, allowable idle time progressively reduces
    /// - Create a pool of 90 connections with a max pool size of 100
    /// - Mark half of them as 'authenticated'
    /// - Wait for 80% of the _currently_ allowable idle time
    /// - Write to 3 of the 'authenticated' connections to reset their idle time
    /// - Write to 10 of the 'unauthenticated' connections to reset their idle time
    /// - Wait until we pass the allowable idle time for unauthenticated
    /// - Verify that the number of connections in the pool is now 55, comprised of
    ///   10 unauthenticated connections, and all 45 of the 'authenticated' ones
    /// - Wait until we pass the cureently allowable idle time for 'authenticated'
    /// - Verify that the number of connections in the pool is now 3, since only
    ///   the 3 that we wrote to earlier are still not 'idle'
    test('test connection pool - 90% capacity - clear idle connection', () {
      int maxPoolSize = 100; // Please don't change this

      var poolInstance = InboundConnectionPool.getInstance();
      poolInstance.init(maxPoolSize);
      List<MockInboundConnectionImpl> connections = [];

      int desiredPoolSize = (maxPoolSize * 0.9).floor();
      int numAuthenticated = 0;
      int numUnauthenticated = 0;
      for (int i = 0; i < desiredPoolSize; i++) {
        var mockConnection = MockInboundConnectionImpl(null, 'mock session $i');
        if (i.isEven) {
          mockConnection.getMetaData().isAuthenticated = true;
          numAuthenticated++;
        } else {
          numUnauthenticated++;
        }
        connections.add(mockConnection);
        poolInstance.add(mockConnection);
      }

      DateTime startTimeAsDateTime = DateTime.now();
      int startTimeAsMillis = startTimeAsDateTime.millisecondsSinceEpoch;

      logger.info('startTimeAsDateTime is $startTimeAsDateTime');

      for (int i = 0; i < desiredPoolSize; i++) {
        connections[i].metaData.lastAccessed = startTimeAsDateTime;
      }

      int unauthenticatedActualAllowableIdleTime = calcActualAllowableIdleTime(
          poolInstance,
          maxPoolSize,
          serverContext.unauthenticatedMinAllowableIdleTimeMillis,
          serverContext.unauthenticatedInboundIdleTimeMillis);
      logger.info(
          "unAuth actual allowed idle time: $unauthenticatedActualAllowableIdleTime");

      // Before simulating activity, let's first sleep until we've reached 80% of the currently allowable idle time for UNAUTHENTICATED connections
      int elapsed = DateTime.now().millisecondsSinceEpoch - startTimeAsMillis;
      var sleepTime = Duration(
          milliseconds:
              (unauthenticatedActualAllowableIdleTime * 0.8).floor() - elapsed);
      logger.info('Sleeping for $sleepTime after initial pool filling to 90%');
      sleep(sleepTime);

      int numAuthToWriteTo = 3;
      int numUnAuthToWriteTo = 10;
      // Let's write to a few authenticated connections, and some more unauthenticated connections
      for (int i = 0; i < numAuthToWriteTo; i++) {
        connections[i * 2].write('test data'); // evens are authenticated
      }
      for (int i = 0; i < numUnAuthToWriteTo; i++) {
        connections[i * 2 + 1].write('test data'); // odds are not authenticated
      }

      expect(poolInstance.getCurrentSize(), desiredPoolSize);

      // pool size should be as expected before checking invalidity
      poolInstance.clearInvalidConnections();
      // no invalid connections should have yet been cleared
      expect(poolInstance.getCurrentSize(), desiredPoolSize);

      // now let's sleep until the unused connections will have been idle for longer than the currently allowable idle time for UNAUTHENTICATED connections
      elapsed = DateTime.now().millisecondsSinceEpoch - startTimeAsMillis;
      sleepTime = Duration(
          milliseconds:
              (unauthenticatedActualAllowableIdleTime - elapsed).abs() + 5);
      logger.info(
          'Sleeping for $sleepTime so that the first batch of unauthenticated connections exceed the allowable idle time');
      sleep(sleepTime);

      // now when we clear invalid connections, we're going to see all of the unused unauthenticated connections returned to pool
      // Since we wrote to 10 unauthenticated connections, that means we will clean up numUnauthenticated - 10
      var preClearSize = poolInstance.getCurrentSize();
      poolInstance.clearInvalidConnections();
      int expected =
          desiredPoolSize - (numUnauthenticated - numUnAuthToWriteTo);
      elapsed = DateTime.now().millisecondsSinceEpoch - startTimeAsMillis;
      logger.info(
          '$elapsed milliseconds after start: expect pool size after unauthenticated clean up to be $expected (pre-clear size was $preClearSize)');
      expect(poolInstance.getCurrentSize(), expected);

      // now let's sleep until the unused connections will have been idle for longer than the currently allowable idle time for AUTHENTICATED connections
      int authenticatedActualAllowableIdleTime = calcActualAllowableIdleTime(
          poolInstance,
          maxPoolSize,
          serverContext.authenticatedMinAllowableIdleTimeMillis,
          serverContext.authenticatedInboundIdleTimeMillis);
      logger.info(
          "auth actual allowed idle time: $authenticatedActualAllowableIdleTime");

      sleepTime = Duration(
          milliseconds: authenticatedActualAllowableIdleTime - elapsed + 10);
      logger.info(
          'Sleeping for $sleepTime so that the first batch of AUTHENTICATED connections exceed the allowable idle time');
      sleep(sleepTime);

      // now when we clear invalid connections, we're going to additionally see all of the unused AUTHENTICATED connections returned to pool
      // Since we wrote to 3 (numAuthToWriteTo variable above) authenticated connections, that means we will clean up an additional numAuthenticated - 3 connections
      // And we'll also be cleaning up all of the UN-Authenticated connections, leaving us
      // with just the 3 'authenticated' connections
      preClearSize = poolInstance.getCurrentSize();
      poolInstance.clearInvalidConnections();
      expected = numAuthToWriteTo;
      elapsed = DateTime.now().millisecondsSinceEpoch - startTimeAsMillis;
      logger.info(
          '$elapsed milliseconds after start : expect pool size after AUTHenticated clean up to be $expected (pre-clear size was $preClearSize)');
      expect(poolInstance.getCurrentSize(), expected);
    });
  });
}

int calcActualAllowableIdleTime(
    poolInstance, maxPoolSize, minAllowableIdleTime, maxAllowableIdleTime) {
  int lowWaterMark =
      (maxPoolSize * serverContext.inboundConnectionLowWaterMarkRatio).floor();
  int numConnectionsOverLwm =
      max(poolInstance.getCurrentSize() - lowWaterMark, 0);
  double idleTimeReductionFactor =
      1 - (numConnectionsOverLwm / (maxPoolSize - lowWaterMark));
  return (((maxAllowableIdleTime - minAllowableIdleTime) *
              idleTimeReductionFactor) +
          minAllowableIdleTime)
      .floor();
}

class MockInboundConnectionImpl extends InboundConnectionImpl {
  MockInboundConnectionImpl(Socket? socket, String sessionId)
      : super(socket, sessionId,
            owningPool: InboundConnectionPool.getInstance());

  @override
  Future<void> close() async {
    getMetaData().isClosed = true;
  }

  @override
  void write(String data) {
    getMetaData().lastAccessed = DateTime.now().toUtc();
  }
}
