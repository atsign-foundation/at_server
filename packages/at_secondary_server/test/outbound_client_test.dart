import 'dart:io';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_commons/at_commons.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late MockSocket mockSocket;

  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.outboundIdleTimeMillis = 50;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
    mockSocket = MockSocket();
    when(() => mockSocket.setOption(SocketOption.tcpNoDelay, true))
        .thenReturn(true);
  });

  group('A group of outbound client tests', () {
    test('test outbound client - invalid outbound client if inbound is invalid',
        () {
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      var client = OutboundClient(connection1, 'bob',
          AtSecondaryServerImpl.getInstance().secondaryAddressFinder);
      client.outboundConnection = OutboundConnectionImpl(mockSocket, 'bob');
      connection1.close();
      expect(client.isInValid(), true);
    });

    test('test outbound client - invalid outbound client idle', () {
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      var client = OutboundClient(connection1, 'bob',
          AtSecondaryServerImpl.getInstance().secondaryAddressFinder);
      client.outboundConnection = OutboundConnectionImpl(mockSocket, 'bob');
      sleep(Duration(
          milliseconds: AtSecondaryServerImpl.getInstance()
                  .serverContext!
                  .outboundIdleTimeMillis +
              1));
      expect(client.isInValid(), true);
    });

    test('test outbound client - valid outbound client', () {
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      var client = OutboundClient(connection1, 'bob',
          AtSecondaryServerImpl.getInstance().secondaryAddressFinder);
      client.outboundConnection = OutboundConnectionImpl(mockSocket, 'bob');
      expect(client.isInValid(), false);
    });

    test(
        'test outbound client - stale connection - connection invalid exception',
        () {
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      var client = OutboundClient(connection1, 'bob',
          AtSecondaryServerImpl.getInstance().secondaryAddressFinder);
      client.outboundConnection = OutboundConnectionImpl(mockSocket, 'bob');
      client.outboundConnection!.metaData.isStale = true;
      expect(
          () => client.lookUp('test', handshake: false),
          throwsA(predicate(
              (dynamic e) => e is OutBoundConnectionInvalidException)));
    });

    test(
        'test outbound client - closed connection - connection invalid exception',
        () {
      var connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      var client = OutboundClient(connection1, 'bob',
          AtSecondaryServerImpl.getInstance().secondaryAddressFinder);
      client.outboundConnection = OutboundConnectionImpl(mockSocket, 'bob');
      client.outboundConnection!.metaData.isClosed = true;
      expect(
          () => client.lookUp('test', handshake: false),
          throwsA(predicate(
              (dynamic e) => e is OutBoundConnectionInvalidException)));
    });
  });
}
