import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:at_utils/at_utils.dart';

import 'test_utils.dart';

var serverContext = AtSecondaryContext();

AtSignLogger logger = AtSignLogger('inbound_connection_pool_test');

void main() async {
  late FakeSocket mockSocket;

  verbTestsSetUpLogging();

  late InboundConnectionPool pool;

  setUpAll(() {
    serverContext.unauthenticatedInboundIdleTimeMillis = 250;
    serverContext.authenticatedInboundIdleTimeMillis = 500;
    serverContext.inboundConnectionLowWaterMarkRatio = 0.5;
    serverContext.unauthenticatedMinAllowableIdleTimeMillis = 20;
    serverContext.authenticatedMinAllowableIdleTimeMillis = 100;
    atServer.serverContext = serverContext;
    atServer.inboundConnectionManager = InboundConnectionManager(
        serverAtSign: alice, poolSize: AtSecondaryConfig.inbound_max_limit);
    pool = atServer.inboundConnectionManager.pool;
    pool.resize(10);

    mockSocket = FakeSocket();
      });
  tearDown(() {
    pool.clearAllConnections();
  });
  group('A group of inbound connection pool test', () {
    test('test connection pool init', () {
      pool.resize(5);
      expect(pool.getCapacity(), 5);
      expect(pool.getCurrentSize(), 0);
    });

    test('test connection pool add connections', () {
      pool.resize(5);
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      var connection2 = InboundConnectionImpl(mockSocket, 'bbb');
      pool.add(connection1);
      pool.add(connection2);
      expect(pool.getCapacity(), 5);
      expect(pool.getCurrentSize(), 2);
    });
    test('test connection pool has capacity', () {
      pool.resize(2);
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      pool.add(connection1);
      expect(pool.hasCapacity(), true);
    });

    test('test connection pool has no capacity', () {
      pool.resize(2);
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      var connection2 = InboundConnectionImpl(mockSocket, 'bbb');
      pool.add(connection1);
      pool.add(connection2);
      expect(pool.hasCapacity(), false);
    });

    test('test connection pool - clear closed connection', () {
      pool.resize(2);
      var connection1 =
          FakeInboundConnectionImpl(mockSocket, 'aaa', owningPool: pool);
      var connection2 =
          FakeInboundConnectionImpl(mockSocket, 'bbb', owningPool: pool);
      pool.add(connection1);
      pool.add(connection2);
      expect(pool.getCurrentSize(), 2);
      connection1.close();
      pool.clearInvalidConnections();
      expect(pool.getCurrentSize(), 1);
    });

    test('test connection pool - clear idle connection', () async {
      pool.resize(10);
      var connection1 =
          FakeInboundConnectionImpl(mockSocket, 'aaa', owningPool: pool);
      var connection2 =
          FakeInboundConnectionImpl(mockSocket, 'bbb', owningPool: pool);
      var connection3 =
          FakeInboundConnectionImpl(mockSocket, 'ccc', owningPool: pool);
      pool.add(connection1);
      pool.add(connection2);
      pool.add(connection3);
      sleep(Duration(
          milliseconds:
              (serverContext.unauthenticatedInboundIdleTimeMillis * 0.9)
                  .floor()));
      await connection2.write('test data');
      expect(pool.getCurrentSize(), 3);
      sleep(Duration(
          milliseconds:
              (serverContext.unauthenticatedInboundIdleTimeMillis * 0.2)
                  .floor()));
      pool.clearInvalidConnections();
      expect(pool.getCurrentSize(), 1);
    });

    /// Verify that, at lowWaterMark, allowable idle time is still as configured by inboundIdleTimeMillis
    test('test connection pool - at lowWaterMark - clear idle connection',
        () async {
      int maxPoolSize = 10;

      pool.resize(maxPoolSize);
      List<AtConnection> connections = [];

      int lowWaterMark =
          (maxPoolSize * serverContext.inboundConnectionLowWaterMarkRatio)
              .floor();
      for (int i = 0; i < lowWaterMark; i++) {
        var mockConnection = FakeInboundConnectionImpl(
            mockSocket, 'mock session $i',
            owningPool: pool);
        connections.add(mockConnection);
        pool.add(mockConnection);
      }

      sleep(Duration(
          milliseconds:
              (serverContext.unauthenticatedInboundIdleTimeMillis * 0.9)
                  .floor()));

      await connections[1].write('test data');
      expect(pool.getCurrentSize(), lowWaterMark);
      sleep(Duration(
          milliseconds:
              ((serverContext.unauthenticatedInboundIdleTimeMillis * 0.1) + 1)
                  .floor()));

      pool.clearInvalidConnections();
      expect(pool.getCurrentSize(), 1);
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
    /// - Wait until we pass the currently allowable idle time for 'authenticated'
    /// - Verify that the number of connections in the pool is now 3, since only
    ///   the 3 that we wrote to earlier are still not 'idle'
    test('test connection pool - 90% capacity - clear idle connection',
        () async {
      int maxPoolSize = 100; // Please don't change this

      pool.resize(maxPoolSize);
      List<FakeInboundConnectionImpl> connections = [];

      int desiredPoolSize = (maxPoolSize * 0.9).floor();
      int numUnauthenticated = 0;
      for (int i = 0; i < desiredPoolSize; i++) {
        var mockConnection = FakeInboundConnectionImpl(
            mockSocket, 'mock session $i',
            owningPool: pool);
        if (i.isEven) {
          mockConnection.metaData.isAuthenticated = true;
        } else {
          numUnauthenticated++;
        }
        connections.add(mockConnection);
        pool.add(mockConnection);
      }

      DateTime startTimeAsDateTime = DateTime.now();
      int startTimeAsMillis = startTimeAsDateTime.millisecondsSinceEpoch;

      logger.info('startTimeAsDateTime is $startTimeAsDateTime');

      for (int i = 0; i < desiredPoolSize; i++) {
        connections[i].metaData.lastAccessed = startTimeAsDateTime;
      }

      int unauthenticatedActualAllowableIdleTime = calcActualAllowableIdleTime(
          pool,
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
        await connections[i * 2].write('test data'); // evens are authenticated
      }
      for (int i = 0; i < numUnAuthToWriteTo; i++) {
        await connections[i * 2 + 1]
            .write('test data'); // odds are not authenticated
      }

      expect(pool.getCurrentSize(), desiredPoolSize);

      // pool size should be as expected before checking invalidity
      pool.clearInvalidConnections();
      // no invalid connections should have yet been cleared
      expect(pool.getCurrentSize(), desiredPoolSize);

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
      var preClearSize = pool.getCurrentSize();
      pool.clearInvalidConnections();
      int expected =
          desiredPoolSize - (numUnauthenticated - numUnAuthToWriteTo);
      elapsed = DateTime.now().millisecondsSinceEpoch - startTimeAsMillis;
      logger.info(
          '$elapsed milliseconds after start: expect pool size after unauthenticated clean up to be $expected (pre-clear size was $preClearSize)');
      expect(pool.getCurrentSize(), expected);

      // now let's sleep until the unused connections will have been idle for longer than the currently allowable idle time for AUTHENTICATED connections
      int authenticatedActualAllowableIdleTime = calcActualAllowableIdleTime(
          pool,
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
      preClearSize = pool.getCurrentSize();
      pool.clearInvalidConnections();
      expected = numAuthToWriteTo;
      elapsed = DateTime.now().millisecondsSinceEpoch - startTimeAsMillis;
      logger.info(
          '$elapsed milliseconds after start : expect pool size after AUTHenticated clean up to be $expected (pre-clear size was $preClearSize)');
      expect(pool.getCurrentSize(), expected);
    });
  });
}

int calcActualAllowableIdleTime(
    pool, maxPoolSize, minAllowableIdleTime, maxAllowableIdleTime) {
  int lowWaterMark =
      (maxPoolSize * serverContext.inboundConnectionLowWaterMarkRatio).floor();
  int numConnectionsOverLwm = max(pool.getCurrentSize() - lowWaterMark, 0);
  double idleTimeReductionFactor =
      1 - (numConnectionsOverLwm / (maxPoolSize - lowWaterMark));
  return (((maxAllowableIdleTime - minAllowableIdleTime) *
              idleTimeReductionFactor) +
          minAllowableIdleTime)
      .floor();
}

class FakeInboundConnectionImpl extends InboundConnectionImpl {
  FakeInboundConnectionImpl(super.socket, String super.sessionId,
      {required super.owningPool});

  @override
  Future<void> close() async {
    metaData.isClosed = true;
  }

  @override
  Future<void> write(String data) async {
    metaData.lastAccessed = DateTime.now().toUtc();
  }
}
