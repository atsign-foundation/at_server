import 'dart:io';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_commons/at_commons.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.outboundIdleTimeMillis = 4000;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
  });

  group('A group of outbound client tests', () {
    test('test outbound client - invalid outbound client if inbound is invalid',
        () {
      var dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      var client = OutboundClient(connection1, 'bob');
      client.outboundConnection = OutboundConnectionImpl(dummySocket, 'bob');
      connection1.close();
      expect(client.isInValid(), true);
    });

    test('test outbound client - invalid outbound client idle', () {
      var dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      var client = OutboundClient(connection1, 'bob');
      client.outboundConnection = OutboundConnectionImpl(dummySocket, 'bob');
      sleep(Duration(seconds: 5));
      expect(client.isInValid(), true);
    });

    test('test outbound client - valid outbound client', () {
      var dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      var client = OutboundClient(connection1, 'bob');
      client.outboundConnection = OutboundConnectionImpl(dummySocket, 'bob');
      expect(client.isInValid(), false);
    });

    test(
        'test outbound client - stale connection - connection invalid exception',
        () {
      var dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      var client = OutboundClient(connection1, 'bob');
      client.outboundConnection = OutboundConnectionImpl(dummySocket, 'bob');
      client.outboundConnection.getMetaData().isStale = true;
      expect(
          () => client.lookUp('test', handshake: false),
          throwsA(predicate(
              (dynamic e) => e is OutBoundConnectionInvalidException)));
    });

    test(
        'test outbound client - closed connection - connection invalid exception',
        () {
      var dummySocket;
      var connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      var client = OutboundClient(connection1, 'bob');
      client.outboundConnection = OutboundConnectionImpl(dummySocket, 'bob');
      client.outboundConnection.getMetaData().isClosed = true;
      expect(
          () => client.lookUp('test', handshake: false),
          throwsA(predicate(
              (dynamic e) => e is OutBoundConnectionInvalidException)));
    });
  });
}
