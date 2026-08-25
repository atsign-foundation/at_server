import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// [FakeSocket] does not implement `write`, so a request sent over it throws
/// before the exchange begins. This accepts the write and never answers, which
/// is what leaves a client holding its request/response mutex.
class SilentPeerSocket extends FakeSocket {
  @override
  void write(Object? obj) {}
}

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
    notifyConnectionsPool = NotifyConnectionsPool(MockSecondaryAddressFinder(),
        DefaultOutboundConnectionFactory(clientCertificateRequired: false));

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

    test('test a reserved slot counts against capacity until the client arrives',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 1;

      expect(poolInstance.tryReserve(), true);
      expect(poolInstance.hasCapacity(), false,
          reason: 'the reserved slot is not free -- a second caller must not'
              ' see it as available while the first is still connecting');
      expect(poolInstance.tryReserve(), false);

      poolInstance.addReserved(newOutboundClient('alice'));
      expect(poolInstance.getCurrentSize(), 1);
      expect(poolInstance.reservedSize, 0,
          reason: 'adding the client consumes the reservation rather than'
              ' leaving the pool permanently one slot smaller');

      poolInstance.clearAllClients();
    });

    test('test releasing a reservation gives the slot back', () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 1;

      expect(poolInstance.tryReserve(), true);
      poolInstance.releaseReservation();

      expect(poolInstance.reservedSize, 0);
      expect(poolInstance.hasCapacity(), true,
          reason: 'a caller whose connect failed must not shrink the pool');
    });

    test('test evicting the least recently used client closes its connection',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var client_1 = newOutboundClient('alice');
      poolInstance.add(client_1);
      await Future.delayed(Duration(milliseconds: 1));
      poolInstance.add(newOutboundClient('bob'));

      expect(client_1.outboundConnection!.metaData.isClosed, false);

      expect(poolInstance.removeLeastRecentlyUsed(), client_1);
      expect(client_1.outboundConnection!.metaData.isClosed, true,
          reason: 'the pool holds the last reference to an evicted client, so'
              ' if it does not close it the socket is never released');

      poolInstance.clearAllClients();
    });

    test('test a client with a request in flight is not the one evicted',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      // Added first, so it is the least recently used and would be the one
      // evicted on lastUsed alone.
      var silentPeer = SilentPeerSocket();
      var busy = OutboundClient(
        InboundConnectionImpl(mockSocket, 'alice'),
        'alice',
        AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
        false,
        outboundConnectionFactory,
      )..outboundConnection = OutboundConnectionImpl(silentPeer, 'alice');
      busy.messageListener = OutboundMessageListener(busy);
      busy.lookupTimeoutMillis = 5000;
      poolInstance.add(busy);

      await Future.delayed(Duration(milliseconds: 2));
      var idle = newOutboundClient('bob');
      poolInstance.add(idle);

      // An exchange the peer never answers, so it keeps holding the socket.
      var inFlight = busy.lookUp('all:phone@alice', handshake: false);
      await Future.delayed(Duration(milliseconds: 20));
      expect(busy.isBusy, true, reason: 'precondition: the exchange is live');

      expect(poolInstance.removeLeastRecentlyUsed(), idle,
          reason: 'lastUsed is stamped when an exchange ENDS, so the client'
              ' that just started one looks least recently used -- evicting it'
              ' would close the socket under the caller waiting on it');
      expect(busy.outboundConnection!.metaData.isClosed, false,
          reason: 'the in-flight client must still have its connection');

      // Let the in-flight request fail so it is not left dangling.
      busy.outboundConnection!.metaData.isClosed = true;
      await expectLater(
          inFlight, throwsA(predicate((dynamic e) => e is AtConnectException)));

      poolInstance.clearAllClients();
    });

    test('test a busy client is not cleared even when it looks invalid',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var silentPeer = SilentPeerSocket();
      var inbound = InboundConnectionImpl(mockSocket, 'alice');
      var busy = OutboundClient(
        inbound,
        'alice',
        AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
        false,
        outboundConnectionFactory,
      )..outboundConnection = OutboundConnectionImpl(silentPeer, 'alice');
      busy.messageListener = OutboundMessageListener(busy);
      busy.lookupTimeoutMillis = 5000;
      poolInstance.add(busy);

      var inFlight = busy.lookUp('all:phone@alice', handshake: false);
      await Future.delayed(Duration(milliseconds: 20));

      // The INBOUND connection goes away, which makes the client look invalid
      // even though the outbound socket is mid-exchange.
      await inbound.close();
      expect(busy.isInValid(), true, reason: 'precondition');
      expect(busy.isBusy, true, reason: 'precondition');

      poolInstance.clearInvalidClients();
      expect(poolInstance.getCurrentSize(), 1,
          reason: 'the outbound socket is still being read from; closing it'
              ' because the inbound side went away destroys it under the'
              ' caller waiting on it');
      expect(busy.outboundConnection!.metaData.isClosed, false);

      busy.outboundConnection!.metaData.isClosed = true;
      await expectLater(
          inFlight, throwsA(predicate((dynamic e) => e is AtConnectException)));
      poolInstance.clearAllClients();
    });

    test('test a busy client that has merely gone idle is not cleared',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var busy = OutboundClient(
        InboundConnectionImpl(mockSocket, 'alice'),
        'alice',
        AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
        false,
        outboundConnectionFactory,
      )..outboundConnection =
          OutboundConnectionImpl(SilentPeerSocket(), 'alice');
      busy.messageListener = OutboundMessageListener(busy);
      busy.lookupTimeoutMillis = 5000;
      poolInstance.add(busy);

      var inFlight = busy.lookUp('all:phone@alice', handshake: false);
      // Past the idle window, so isInValid() is true on the OUTBOUND side --
      // but only because nothing has been written recently, which is exactly
      // what waiting on a slow peer looks like.
      await Future.delayed(Duration(milliseconds: outboundIdleTimeMillis + 50));
      expect(busy.isInValid(), true, reason: 'precondition: looks invalid');
      expect(busy.isBusy, true, reason: 'precondition: still exchanging');

      poolInstance.clearInvalidClients();
      expect(poolInstance.getCurrentSize(), 1,
          reason: 'idle is not dead: closing a client that is waiting on a'
              ' slow peer destroys the socket under the caller');

      busy.outboundConnection!.metaData.isClosed = true;
      await expectLater(
          inFlight, throwsA(predicate((dynamic e) => e is AtConnectException)));
      poolInstance.clearAllClients();
    });

    test('test a busy client whose socket has actually gone IS cleared',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 5;

      var busy = OutboundClient(
        InboundConnectionImpl(mockSocket, 'alice'),
        'alice',
        AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
        false,
        outboundConnectionFactory,
      )..outboundConnection =
          OutboundConnectionImpl(SilentPeerSocket(), 'alice');
      busy.messageListener = OutboundMessageListener(busy);
      busy.lookupTimeoutMillis = 5000;
      poolInstance.add(busy);

      var inFlight = busy.lookUp('all:phone@alice', handshake: false);
      await Future.delayed(Duration(milliseconds: 20));
      expect(busy.isBusy, true, reason: 'precondition');

      // Mark it stale and sweep in the same synchronous run, so the in-flight
      // read has not had a chance to notice and release.
      busy.outboundConnection!.metaData.isStale = true;
      poolInstance.clearInvalidClients();
      expect(poolInstance.getCurrentSize(), 0,
          reason: 'there is nothing left to protect once the socket itself is'
              ' gone, and leaving it hands the next caller a dead connection');

      await expectLater(
          inFlight, throwsA(predicate((dynamic e) => e is AtConnectException)));
      poolInstance.clearAllClients();
    });

    test('test every pooled client being busy means nothing is evicted',
        () async {
      var poolInstance = outboundClientPool;
      poolInstance.size = 2;

      var clients = <OutboundClient>[];
      var pending = <Future<String?>>[];
      for (var name in ['alice', 'bob']) {
        var c = OutboundClient(
          InboundConnectionImpl(mockSocket, name),
          name,
          AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
          false,
          outboundConnectionFactory,
        )..outboundConnection =
            OutboundConnectionImpl(SilentPeerSocket(), name);
        c.messageListener = OutboundMessageListener(c);
        c.lookupTimeoutMillis = 5000;
        poolInstance.add(c);
        clients.add(c);
        pending.add(c.lookUp('all:phone@$name', handshake: false));
      }
      await Future.delayed(Duration(milliseconds: 20));

      expect(poolInstance.removeLeastRecentlyUsed(), isNull,
          reason: 'a pool full of live work has nothing safe to evict, and'
              ' must say so rather than destroying an exchange');
      expect(poolInstance.getCurrentSize(), 2);

      for (var i = 0; i < clients.length; i++) {
        clients[i].outboundConnection!.metaData.isClosed = true;
        await expectLater(pending[i],
            throwsA(predicate((dynamic e) => e is AtConnectException)));
      }
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
