import 'dart:io';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

void main() async {
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.outboundIdleTimeMillis = 2000;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
  });
  tearDown(() {
    OutboundClientPool().clearAllClients();
  });
  group('A group of outbound client pool test', () {
    test('test outbound client pool init', () {
      OutboundClientPool().init((5));
      expect(OutboundClientPool().getCapacity(), 5);
      expect(OutboundClientPool().getCurrentSize(), 0);
    });

    test('test connection pool add clients', () {
      var poolInstance = OutboundClientPool();
      poolInstance.init(5);
      var dummySocket_1, dummySocket_2;
      var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
      var client_1 = OutboundClient(inboundConnection_1, 'alice');
      client_1.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'alice');
      var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
      var client_2 = OutboundClient(inboundConnection_2, 'bob');
      client_2.outboundConnection =
          OutboundConnectionImpl(dummySocket_1, 'bob');
      poolInstance.add(client_1);
      poolInstance.add(client_2);
      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);
    });
    test('test client pool - invalid clients', () {
      var poolInstance = OutboundClientPool();
      poolInstance.init(5);
      var dummySocket_1, dummySocket_2, dummySocket_3;
      var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
      var client_1 = OutboundClient(inboundConnection_1, 'alice');
      client_1.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'alice');
      var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
      var client_2 = OutboundClient(inboundConnection_2, 'bob');
      client_2.outboundConnection =
          OutboundConnectionImpl(dummySocket_1, 'bob');
      poolInstance.add(client_1);
      poolInstance.add(client_2);
      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);
      sleep(Duration(seconds: 3));
      var inboundConnection_3 = InboundConnectionImpl(dummySocket_3, 'ccc');
      var client_3 = OutboundClient(inboundConnection_3, 'charlie');
      client_3.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'charlie');
      poolInstance.add(client_3);
      poolInstance.clearInvalidClients();
      expect(poolInstance.getCurrentSize(), 1);
    });

    test('test connection pool remove all clients', () {
      var poolInstance = OutboundClientPool();
      poolInstance.init(5);
      var dummySocket_1, dummySocket_2;
      var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
      var client_1 = OutboundClient(inboundConnection_1, 'alice');
      client_1.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'alice');
      var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
      var client_2 = OutboundClient(inboundConnection_2, 'bob');
      client_2.outboundConnection =
          OutboundConnectionImpl(dummySocket_1, 'bob');
      poolInstance.add(client_1);
      poolInstance.add(client_2);
      expect(poolInstance.getCapacity(), 5);
      expect(poolInstance.getCurrentSize(), 2);
      poolInstance.clearAllClients();
      expect(poolInstance.getCurrentSize(), 0);
    });
  });
}
