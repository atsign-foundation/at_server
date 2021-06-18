import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.inboundIdleTimeMillis = 10000;
    AtSecondaryServerImpl.getInstance().serverContext = serverContext;
  });

  tearDown(() {
    InboundConnectionManager.getInstance().removeAllConnections();
  });

  group('A group of inbound connection manager tests', () {
    test('test inbound connection manager - create connection ', () {
      var connManager = InboundConnectionManager.getInstance();
      var dummySocket;
      connManager.init(5);
      var createdConnection =
          connManager.createConnection(dummySocket, sessionId: 'aaa');
      expect(createdConnection.getMetaData().sessionID, 'aaa');
      expect(createdConnection.getMetaData().isCreated, true);
    });

    test('test inbound connection manager - current pool size', () {
      var connManager = InboundConnectionManager.getInstance();
      connManager.init(2);
      var dummySocket;
      connManager.createConnection(dummySocket, sessionId: 'aaa');
      expect(ConnectionUtil.getActiveConnectionSize(), 1);
    });

    test('test inbound connection manager - current pool size no connections',
        () {
      expect(ConnectionUtil.getActiveConnectionSize(), 0);
    });

    test('test inbound connection manager - connect limit test', () {
      var connManager = InboundConnectionManager.getInstance();
      var dummySocket;
      connManager.init(2);
      connManager.createConnection(dummySocket, sessionId: 'aaa');
      connManager.createConnection(dummySocket, sessionId: 'bbb');
      expect(
          () => connManager.createConnection(dummySocket, sessionId: 'ccc'),
          throwsA(predicate((dynamic e) =>
              e is InboundConnectionLimitException &&
              e.message == 'max limit reached on inbound pool')));
      ;
    });

    test('test inbound connection manager - has capacity true', () {
      var connManager = InboundConnectionManager.getInstance();
      var dummySocket;
      connManager.init(5);
      connManager.createConnection(dummySocket, sessionId: 'aaa');
      connManager.createConnection(dummySocket, sessionId: 'bbb');
      connManager.createConnection(dummySocket, sessionId: 'ccc');
      expect(connManager.hasCapacity(), true);
    });

    test('test inbound connection manager - has capacity false', () {
      var connManager = InboundConnectionManager.getInstance();
      var dummySocket;
      connManager.init(3);
      connManager.createConnection(dummySocket, sessionId: 'aaa');
      connManager.createConnection(dummySocket, sessionId: 'bbb');
      connManager.createConnection(dummySocket, sessionId: 'ccc');
      expect(connManager.hasCapacity(), false);
    });

    test('test inbound connection manager -clear connections', () {
      var connManager = InboundConnectionManager.getInstance();
      var dummySocket;
      connManager.init(3);
      connManager.createConnection(dummySocket, sessionId: 'aaa');
      connManager.createConnection(dummySocket, sessionId: 'bbb');
      connManager.createConnection(dummySocket, sessionId: 'ccc');
      connManager.removeAllConnections();
      expect(ConnectionUtil.getActiveConnectionSize(), 0);
    });
  });
}
