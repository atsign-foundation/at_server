import 'dart:io';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';
import 'package:at_commons/at_commons.dart';
import 'dummy_socket.dart';

void main() {
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.inboundIdleTimeMillis = 5000;
    serverContext.outboundIdleTimeMillis = 3000;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
  });

  group('A group of outbound client manager tests', () {
    test('test outbound client manager - create new client ', () {
      var dummySocket = DummySocket.getInstance();
      var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(5);
      var outBoundClient = clientManager.getClient('bob', inboundConnection)!;
      expect(outBoundClient.toAtSign, 'bob');
      outBoundClient.outboundConnection =
          OutboundConnectionImpl(DummySocket.getInstance(), '@bob');
      expect(clientManager.getActiveConnectionSize(), 1);
    });

    test('test outbound client manager - get existing client ', () {
      var dummySocket = DummySocket.getInstance();
      var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(5);
      var outBoundClient_1 = clientManager.getClient('bob', inboundConnection,
          isHandShake: false)!;
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(DummySocket.getInstance(), '@bob');
      expect(outBoundClient_1.toAtSign, 'bob');
      expect(clientManager.getActiveConnectionSize(), 1);
      var outBoundClient_2 = clientManager.getClient('bob', inboundConnection,
          isHandShake: false)!;
      outBoundClient_2.outboundConnection =
          OutboundConnectionImpl(DummySocket.getInstance(), '@bob');
      expect(outBoundClient_1.toAtSign == outBoundClient_2.toAtSign, true);
      expect(clientManager.getActiveConnectionSize(), 1);
    });

    test('test outbound client manager - add multiple clients ', () {
      var dummySocket_1 = DummySocket.getInstance();
      var dummySocket_2 = DummySocket.getInstance();
      var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
      var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(5);
      var outBoundClient_1 =
          clientManager.getClient('alice', inboundConnection_1)!;
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(DummySocket.getInstance(), '@alice');
      var outBoundClient_2 =
          clientManager.getClient('bob', inboundConnection_2)!;
      outBoundClient_2.outboundConnection =
          OutboundConnectionImpl(DummySocket.getInstance(), '@bob');
      expect(outBoundClient_1.toAtSign, 'alice');
      expect(outBoundClient_2.toAtSign, 'bob');
      expect(clientManager.getActiveConnectionSize(), 2);
    });

    test('test outbound client manager - capacity exceeded ', () {
      var dummySocket_1 = DummySocket.getInstance();
      var dummySocket_2 = DummySocket.getInstance();
      var dummySocket_3 = DummySocket.getInstance();
      var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
      var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
      var inboundConnection_3 = InboundConnectionImpl(dummySocket_3, 'ccc');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(2);
      var outboundClient1 = clientManager.getClient('alice', inboundConnection_1);
      outboundClient1!.outboundConnection = OutboundConnectionImpl(DummySocket.getInstance(), '@alice');
      var outboundClient2 = clientManager.getClient('bob', inboundConnection_2);
      outboundClient2!.outboundConnection = OutboundConnectionImpl(DummySocket.getInstance(), '@bob');
      expect(
          () => clientManager.getClient('charlie', inboundConnection_3),
          throwsA(predicate((dynamic e) =>
              e is OutboundConnectionLimitException &&
              e.message == 'max limit reached on outbound pool')));
    });

    test(
        'test outbound client manager - inbound is closed, outbound client is invalid',
        () {
      var dummySocket = DummySocket.getInstance();
      var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(5);
      var outBoundClient_1 = clientManager.getClient('bob', inboundConnection)!;
      inboundConnection.close();
      expect(outBoundClient_1.isInValid(), true);
    });

    test(
        'test outbound client manager - outbound client is closed, inbound is still valid',
        () {
      var dummySocket_1 = DummySocket.getInstance(),
          dummySocket_2 = DummySocket.getInstance();
      var inboundConnection = InboundConnectionImpl(dummySocket_1, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(5);
      var outBoundClient_1 = clientManager.getClient('bob', inboundConnection)!;
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'bob');
      outBoundClient_1.close();
      expect(inboundConnection.isInValid(), false);
    });

    test(
        'test outbound client manager - outbound client is idle and becomes invalid',
        () {
      var dummySocket_1 = DummySocket.getInstance(),
          dummySocket_2 = DummySocket.getInstance();
      var inboundConnection = InboundConnectionImpl(dummySocket_1, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(5);
      var outBoundClient_1 = clientManager.getClient('bob', inboundConnection)!;
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'bob');
      sleep(Duration(seconds: 4));
      expect(outBoundClient_1.isInValid(), true);
    });
  });
}
