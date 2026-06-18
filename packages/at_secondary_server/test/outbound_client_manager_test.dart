import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  FakeSocket mockSocket_1 = FakeSocket();
  FakeSocket mockSocket_2 = FakeSocket();

  verbTestsSetUpLogging();

  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.unauthenticatedInboundIdleTimeMillis = 50;
    serverContext.unauthenticatedOutboundIdleTimeMillis = 30;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
    // Wire the outbound deps the manager injects into each OutboundClient
    // (production wires these in AtSecondaryServerImpl.start()).
    AtSecondaryServerImpl.getInstance().outboundClientManager
      ..cachePublicKey = ((name, data) async {})
      ..currentAtSign = alice
      ..signingKey = ''
      ..keyStore = MockAtKeyValueStore();
  });

  group('A group of outbound client manager tests', () {
    test('test outbound client manager - create new client ', () async {
      var inboundConnection = InboundConnectionImpl(mockSocket_1, 'aaa');
      var clientManager =
          AtSecondaryServerImpl.getInstance().outboundClientManager;
      clientManager.poolSize = 5;
      final OutboundClient outBoundClient = await clientManager.getClient(
        '@bob',
        inboundConnection,
        handshakeRequired: false,
        connect: false,
      );
      expect(outBoundClient.toAtSign, '@bob');
      expect(clientManager.getActiveConnectionSize(), 1);
    });

    // test('test outbound client manager - get existing client ', () {
    //   var dummySocket = DummySocket(1);
    //   var inboundConnection = InboundConnectionImpl(mockSocket, 'aaa');
    //   var clientManager = AtSecondaryServerImpl.getInstance().outboundClientManager;
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
    //   var mockSocket_1 = DummySocket(1);
    //   var dummySocket_2 = DummySocket(2);
    //   var inboundConnection_1 = InboundConnectionImpl(mockSocket_1, 'aaa');
    //   var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
    //   var clientManager = AtSecondaryServerImpl.getInstance().outboundClientManager;
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
    //   //var mockSocket_1 = DummySocket(1);
    //   var dummySocket_2 = DummySocket(2);
    //   var dummySocket_3 = DummySocket(3);
    //   var inboundConnection_1 = InboundConnectionImpl(mockSocket_1, 'aaa');
    //   var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
    //   var inboundConnection_3 = InboundConnectionImpl(dummySocket_3, 'ccc');
    //   var clientManager = AtSecondaryServerImpl.getInstance().outboundClientManager;
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
        () async {
      final InboundConnectionImpl inboundConnection =
          InboundConnectionImpl(mockSocket_1, 'aaa');
      var clientManager =
          AtSecondaryServerImpl.getInstance().outboundClientManager;
      clientManager.poolSize = 5;
      final OutboundClient outBoundClient_1 = await clientManager.getClient(
        '@bob',
        inboundConnection,
        handshakeRequired: true,
        connect: false,
      );
      await inboundConnection.close();
      expect(outBoundClient_1.isInValid(), true);
    });

    test(
        'test outbound client manager - outbound client is closed, inbound is still valid',
        () async {
      var inboundConnection = InboundConnectionImpl(mockSocket_1, 'aaa');
      var clientManager =
          AtSecondaryServerImpl.getInstance().outboundClientManager;
      clientManager.poolSize = 5;
      final OutboundClient outBoundClient_1 = await clientManager.getClient(
        'bob',
        inboundConnection,
        handshakeRequired: false,
        connect: false,
      );
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(mockSocket_2, 'bob');
      outBoundClient_1.close();
      expect(inboundConnection.isInValid(), false);
    });

    test(
        'test outbound client manager - outbound client is idle and becomes invalid',
        () async {
      var inboundConnection = InboundConnectionImpl(mockSocket_1, 'aaa');
      var clientManager =
          AtSecondaryServerImpl.getInstance().outboundClientManager;
      clientManager.poolSize = 5;
      final OutboundClient outBoundClient_1 = await clientManager.getClient(
        'bob',
        inboundConnection,
        handshakeRequired: false,
        connect: false,
      );
      outBoundClient_1.outboundConnection =
          OutboundConnectionImpl(mockSocket_2, 'bob');
      expect(outBoundClient_1.isInValid(), false);
      sleep(Duration(
          milliseconds: AtSecondaryServerImpl.getInstance()
                  .serverContext!
                  .unauthenticatedOutboundIdleTimeMillis ~/
              2));
      expect(outBoundClient_1.isInValid(), false);
      sleep(Duration(
          milliseconds: AtSecondaryServerImpl.getInstance()
                      .serverContext!
                      .unauthenticatedOutboundIdleTimeMillis ~/
                  2 +
              1));
      expect(outBoundClient_1.isInValid(), true);
    });
  });
}
