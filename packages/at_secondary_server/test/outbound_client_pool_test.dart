import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

void main() async {
  // ignore: prefer_typing_uninitialized_variables
  late OutboundClientPool outboundClientPool;
  final int outboundIdleTimeMillis = 200;
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.outboundIdleTimeMillis = outboundIdleTimeMillis;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
    outboundClientPool = OutboundClientPool();

    NotifyConnectionsPool.getInstance().size = 2;
  });

  tearDown(() {
    outboundClientPool.clearAllClients();
    NotifyConnectionsPool.getInstance().pool.clearAllClients();
  });

  group('A group of outbound client pool test', () {
    test('test outbound client pool init', () {
      outboundClientPool.size = 5;
      expect(outboundClientPool.getCapacity(), 5);
      expect(outboundClientPool.getCurrentSize(), 0);
    });

    Socket? dummySocket;
    OutboundClient newOutboundClient(String toAtSign) {
      var inboundConnection = InboundConnectionImpl(dummySocket, toAtSign);
      OutboundClient outboundClient =
          OutboundClient(inboundConnection, toAtSign);
      outboundClient.outboundConnection =
          OutboundConnectionImpl(dummySocket, toAtSign);

      return outboundClient;
    }

    test('test connection pool add clients', () {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var client_1 = newOutboundClient('alice');
      poolInstance.add(client_1);
      var client_2 = newOutboundClient('bob');
      poolInstance.add(client_2);

      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);
    });

    test('test client pool - invalid clients', () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var client_1 = newOutboundClient('alice');
      poolInstance.add(client_1);
      var client_2 = newOutboundClient('bob');
      poolInstance.add(client_2);

      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);

      await Future.delayed(
          Duration(milliseconds: outboundIdleTimeMillis + 100));

      var client_3 = newOutboundClient('charlie');
      poolInstance.add(client_3);

      poolInstance.clearInvalidClients();
      expect(poolInstance.getCurrentSize(), 1);
    });

    test('test connection pool remove all clients', () {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var client_1 = newOutboundClient('alice');
      poolInstance.add(client_1);
      var client_2 = newOutboundClient('bob');
      poolInstance.add(client_2);

      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);

      poolInstance.clearAllClients();
      expect(poolInstance.getCurrentSize(), 0);
    });

    test('test connection pool remove least recently used when pool size >= 2',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var client_1 = newOutboundClient('alice');
      poolInstance.add(client_1);

      await Future.delayed(Duration(milliseconds: 1));
      var client_2 = newOutboundClient('bob');
      poolInstance.add(client_2);

      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);
      expect(poolInstance.hasCapacity(), true);

      await Future.delayed(Duration(milliseconds: 1));

      client_1.lastUsed = DateTime.now();

      expect(poolInstance.removeLeastRecentlyUsed(), client_2);
      expect(poolInstance.getCurrentSize(), 1);

      poolInstance.clearAllClients();
    });

    test('test connection pool remove least recently used when pool size <= 1',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      expect(poolInstance.getCurrentSize(), 0);
      expect(poolInstance.removeLeastRecentlyUsed(), null);
      expect(poolInstance.getCurrentSize(), 0);

      var client_1 = newOutboundClient('alice');
      poolInstance.add(client_1);

      expect(poolInstance.getCurrentSize(), 1);
      expect(poolInstance.removeLeastRecentlyUsed(), null);
      expect(poolInstance.getCurrentSize(), 1);

      await Future.delayed(Duration(milliseconds: 1));
      var client_2 = newOutboundClient('bob');
      poolInstance.add(client_2);

      expect(poolInstance.getCurrentSize(), 2);
      expect(poolInstance.removeLeastRecentlyUsed(), client_1);
      expect(poolInstance.getCurrentSize(), 1);

      poolInstance.clearAllClients();
    });

    test(
        'test notify connections pool removes least recently used when at capacity, with lastUsed as per order of OutboundClient creation',
        () async {
      NotifyConnectionsPool notifyConnectionPool =
          NotifyConnectionsPool.getInstance();

      notifyConnectionPool.size = 2;
      expect(notifyConnectionPool.getCapacity(), 2);

      var alice = notifyConnectionPool.get('alice');
      expect(notifyConnectionPool.getCapacity(), 1);

      await Future.delayed(Duration(milliseconds: 1));
      var bob = notifyConnectionPool.get('bob');
      expect(notifyConnectionPool.getCapacity(), 0);
      expect(notifyConnectionPool.pool.clients()[0], alice);
      expect(notifyConnectionPool.pool.clients()[1], bob);

      await Future.delayed(Duration(milliseconds: 1));
      var charlie = notifyConnectionPool.get(
          'charlie'); // as there is no capacity, alice should be evicted as the least recently used
      expect(notifyConnectionPool.getCapacity(), 0);
      expect(notifyConnectionPool.pool.clients()[0], bob);
      expect(notifyConnectionPool.pool.clients()[1], charlie);
    });

    test(
        'test notify connections pool removes least recently used when at capacity, with lastUsed CHANGED compared with order of object creation',
        () async {
      NotifyConnectionsPool notifyConnectionPool =
          NotifyConnectionsPool.getInstance();

      notifyConnectionPool.size = 2;
      expect(notifyConnectionPool.getCapacity(), 2);

      var alice = notifyConnectionPool.get('alice');
      expect(notifyConnectionPool.getCapacity(), 1);

      await Future.delayed(Duration(milliseconds: 1));
      var bob = notifyConnectionPool.get('bob');
      expect(notifyConnectionPool.getCapacity(), 0);

      alice.lastUsed = DateTime.now();
      expect(notifyConnectionPool.pool.clients()[0], bob);
      expect(notifyConnectionPool.pool.clients()[1], alice);

      await Future.delayed(Duration(milliseconds: 1));
      var charlie = notifyConnectionPool.get(
          'charlie'); // as there is no capacity, bob should be evicted as the least recently used
      expect(notifyConnectionPool.getCapacity(), 0);
      expect(notifyConnectionPool.pool.clients()[0], alice);
      expect(notifyConnectionPool.pool.clients()[1], charlie);
    });
  });
}
