import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() async {
  // ignore: prefer_typing_uninitialized_variables
  late OutboundClientPool outboundClientPool;
  late NotifyConnectionsPool notifyConnectionsPool;
  final int outboundIdleTimeMillis = 200;
  FakeSocket mockSocket = FakeSocket();

  verbTestsSetUpLogging();

  setUpAll(() {});

  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.unauthenticatedOutboundIdleTimeMillis =
        outboundIdleTimeMillis;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
    outboundClientPool = OutboundClientPool();
    notifyConnectionsPool = NotifyConnectionsPool(
        MockSecondaryAddressFinder(),
        DefaultOutboundConnectionFactory(clientCertificateRequired: false),
        AtSecondaryServerImpl.getInstance().signingKeyManager);

    notifyConnectionsPool.size = 2;
  });

  tearDown(() {
    outboundClientPool.clearAllClients();
    notifyConnectionsPool.outboundClientPool.clearAllClients();
  });

  group('A group of outbound client pool test', () {
    OutboundConnectionFactory outboundConnectionFactory =
        DefaultOutboundConnectionFactory(clientCertificateRequired: false);
    test('test outbound client pool init', () {
      outboundClientPool.size = 5;
      expect(outboundClientPool.getCapacity(), 5);
      expect(outboundClientPool.getCurrentSize(), 0);
    });

    OutboundClient newOutboundClient(String toAtSign) {
      var inboundConnection = InboundConnectionImpl(mockSocket, toAtSign);
      OutboundClient outboundClient = OutboundClient(
        inboundConnection,
        toAtSign,
        AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
        false,
        outboundConnectionFactory,
        AtSecondaryServerImpl.getInstance().signingKeyManager,
      );
      outboundClient.outboundConnection =
          OutboundConnectionImpl(mockSocket, toAtSign);

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
      notifyConnectionsPool.size = 2;
      expect(notifyConnectionsPool.getCapacity(), 2);

      OutboundClient toAlice = await notifyConnectionsPool.getOutboundClient(
        '@alice',
        connect: false,
      );
      expect(notifyConnectionsPool.getCapacity(), 1);

      await Future.delayed(Duration(milliseconds: 1));
      OutboundClient toBob = await notifyConnectionsPool.getOutboundClient(
        '@bob',
        connect: false,
      );
      expect(notifyConnectionsPool.getCapacity(), 0);
      expect(notifyConnectionsPool.outboundClientPool.clients()[0], toAlice);
      expect(notifyConnectionsPool.outboundClientPool.clients()[1], toBob);

      await Future.delayed(Duration(milliseconds: 1));
      OutboundClient toCharlie = await notifyConnectionsPool.getOutboundClient(
        '@charlie',
        connect: false,
      ); // as there is no capacity, alice should be evicted as the least recently used
      expect(notifyConnectionsPool.getCapacity(), 0);
      expect(notifyConnectionsPool.outboundClientPool.clients()[0], toBob);
      expect(notifyConnectionsPool.outboundClientPool.clients()[1], toCharlie);
    });

    test(
        'test notify connections pool removes least recently used when at capacity, with lastUsed CHANGED compared with order of object creation',
        () async {
      notifyConnectionsPool.size = 2;
      expect(notifyConnectionsPool.getCapacity(), 2);

      final OutboundClient toAlice =
          await notifyConnectionsPool.getOutboundClient(
        '@alice',
        connect: false,
      );
      expect(notifyConnectionsPool.getCapacity(), 1);

      await Future.delayed(Duration(milliseconds: 1));
      final OutboundClient toBob =
          await notifyConnectionsPool.getOutboundClient(
        '@bob',
        connect: false,
      );
      expect(notifyConnectionsPool.getCapacity(), 0);

      toAlice.lastUsed = DateTime.now();
      expect(notifyConnectionsPool.outboundClientPool.clients()[0], toBob);
      expect(notifyConnectionsPool.outboundClientPool.clients()[1], toAlice);

      await Future.delayed(Duration(milliseconds: 1));
      OutboundClient toCharlie = await notifyConnectionsPool.getOutboundClient(
        '@charlie',
        connect: false,
      ); // as there is no capacity, bob should be evicted as the least recently used
      expect(notifyConnectionsPool.getCapacity(), 0);
      expect(notifyConnectionsPool.outboundClientPool.clients()[0], toAlice);
      expect(notifyConnectionsPool.outboundClientPool.clients()[1], toCharlie);
    });
  });
}
