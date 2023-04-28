import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.inboundIdleTimeMillis = 50;
    serverContext.outboundIdleTimeMillis = 30;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
  });

  group('A group of outbound client manager tests', () {
    test('test outbound client manager - create new client ', () {
      Socket? dummySocket;
      var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.poolSize = 5;
      var outBoundClient = clientManager.getClient('bob', inboundConnection);
      expect(outBoundClient.toAtSign, 'bob');
      expect(clientManager.getActiveConnectionSize(), 1);
    });

    // test('test outbound client manager - get existing client ', () {
    //   var dummySocket = DummySocket(1);
    //   var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
    //   var clientManager = OutboundClientManager.getInstance();
    //   clientManager.init(5);
    //   var outBoundClient_1 =
    //       clientManager.getClient('bob', inboundConnection, isHandShake: false)!;
    //   expect(outBoundClient_1.toAtSign, 'bob');
    //   expect(clientManager.getActiveConnectionSize(), 1);
    //   var outBoundClient_2 =
    //       clientManager.getClient('bob', inboundConnection, isHandShake: false)!;
    //   expect(outBoundClient_1.toAtSign == outBoundClient_2.toAtSign, true);
    //   expect(clientManager.getActiveConnectionSize(), 1);
    // });

    // test('test outbound client manager - add multiple clients ', () {
    //   var dummySocket_1 = DummySocket(1);
    //   var dummySocket_2 = DummySocket(2);
    //   var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
    //   var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
    //   var clientManager = OutboundClientManager.getInstance();
    //   clientManager.init(5);
    //   var outBoundClient_1 =
    //       clientManager.getClient('alice', inboundConnection_1)!;
    //   var outBoundClient_2 =
    //       clientManager.getClient('bob', inboundConnection_2)!;
    //   expect(outBoundClient_1.toAtSign, 'alice');
    //   expect(outBoundClient_2.toAtSign, 'bob');
    //   expect(clientManager.getActiveConnectionSize(), 2);
    // });

    // test('test outbound client manager - capacity exceeded ', () {
    //   //var dummySocket_1 = DummySocket(1);
    //   var dummySocket_2 = DummySocket(2);
    //   var dummySocket_3 = DummySocket(3);
    //   var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
    //   var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
    //   var inboundConnection_3 = InboundConnectionImpl(dummySocket_3, 'ccc');
    //   var clientManager = OutboundClientManager.getInstance();
    //   clientManager.init(2);
    //   clientManager.getClient('alice', inboundConnection_1);
    //   clientManager.getClient('bob', inboundConnection_2);
    //   expect(
    //       () => clientManager.getClient('charlie', inboundConnection_3),
    //       throwsA(predicate((dynamic e) =>
    //           e is OutboundConnectionLimitException &&
    //           e.message == 'max limit reached on outbound pool')));
    // });

    test(
        'test outbound client manager - inbound is closed, outbound client is invalid',
        () {
      Socket? dummySocket;
      var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.poolSize = 5;
      var outBoundClient_1 = clientManager.getClient('bob', inboundConnection);
      inboundConnection.close();
      expect(outBoundClient_1.isInValid(), true);
    });

    test(
        'test outbound client manager - outbound client is closed, inbound is still valid',
        () {
      Socket? dummySocket_1, dummySocket_2;
      var inboundConnection = InboundConnectionImpl(dummySocket_1, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.poolSize = 5;
      var outBoundClient_1 = clientManager.getClient('bob', inboundConnection);
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'bob');
      outBoundClient_1.close();
      expect(inboundConnection.isInValid(), false);
    });

    test(
        'test outbound client manager - outbound client is idle and becomes invalid',
        () {
      Socket? dummySocket_1, dummySocket_2;
      var inboundConnection = InboundConnectionImpl(dummySocket_1, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.poolSize = 5;
      var outBoundClient_1 = clientManager.getClient('bob', inboundConnection);
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(dummySocket_2, 'bob');
      expect(outBoundClient_1.isInValid(), false);
      sleep(Duration(
          milliseconds: AtSecondaryServerImpl.getInstance()
                  .serverContext!
                  .outboundIdleTimeMillis ~/
              2));
      expect(outBoundClient_1.isInValid(), false);
      sleep(Duration(
          milliseconds: AtSecondaryServerImpl.getInstance()
                      .serverContext!
                      .outboundIdleTimeMillis ~/
                  2 +
              1));
      expect(outBoundClient_1.isInValid(), true);
    });
  });
}
