import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart'
    show AuthType, InboundConnection;
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  const int limit = 64 * 1024;
  final List<(InboundConnectionImpl, Socket)> pairs = [];
  AtSecondaryContext? priorContext;
  int sessions = 0;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    priorContext = AtSecondaryServerImpl.getInstance().serverContext;
    AtSecondaryServerImpl.getInstance().serverContext = AtSecondaryContext()
      ..inboundMaxUnsentBytes = limit;
    atServer.inboundConnectionManager =
        InboundConnectionManager(serverAtSign: alice, poolSize: 10);
    atServer.statsNotificationService.currentAtSign = alice;
  });

  tearDown(() async {
    for (final (InboundConnectionImpl server, Socket client) in pairs) {
      client.destroy();
      await server.close();
    }
    pairs.clear();
    AtSecondaryServerImpl.getInstance().serverContext = priorContext;
    await verbTestsTearDown();
  });

  /// A monitor connection in the pool, with the listener that removes it from
  /// the pool when it closes; its client reads only when [reading].
  Future<(InboundConnectionImpl, List<int>)> monitorConnection(
      {required bool reading}) async {
    final ServerSocket listener =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final Future<Socket> accepted = listener.first;
    final Socket client =
        await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
    final Socket serverSide = await accepted;
    await listener.close();
    final InboundConnectionImpl server = atServer.inboundConnectionManager
        .createSocketConnection(serverSide,
            sessionId: 'session-${++sessions}') as InboundConnectionImpl;
    server.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    server.acceptRequests((String command, InboundConnection c) async {});
    final List<int> received = <int>[];
    final StreamSubscription<Uint8List> subscription =
        client.listen(received.addAll);
    if (!reading) {
      subscription.pause();
    }
    pairs.add((server, client));
    final MonitorVerbHandler handler =
        MonitorVerbHandler(keyValueStore, notificationManager);
    await handler.processVerb(Response(), handler.parse('monitor'), server);
    return (server, received);
  }

  String line(String id, int valueLength) {
    final AtNotification n = (AtNotificationBuilder()
          ..id = id
          ..fromAtSign = bob
          ..toAtSign = alice
          ..notification = '@alice:phone.wavi@bob'
          ..atValue = 'v' * valueLength
          ..notificationDateTime = DateTime.now()
          ..type = NotificationType.received)
        .build();
    return 'notification: ${jsonEncode(n.mapForClient)}\n';
  }

  group(
      'Given two monitor connections, the first just under the unsent-bytes limit',
      () {
    test(
        'when stats are written, then the first is closed and the second still gets its stats',
        () async {
      final (InboundConnectionImpl first, _) =
          await monitorConnection(reading: false);
      final (InboundConnectionImpl second, List<int> secondReceived) =
          await monitorConnection(reading: true);
      int i = 0;
      while (first.unsentBytes == 0) {
        await first.write(line('fill-${i++}', 8 * 1024));
        await pumpEventQueue(times: 2);
      }
      while (limit - first.unsentBytes > 10 * 1024) {
        await first.write(line('fill-${i++}', 8 * 1024));
      }
      final int overhead = utf8.encode(line('top-up', 0)).length;
      await first
          .write(line('top-up', limit - first.unsentBytes - 100 - overhead));
      expect(first.unsentBytes, inInclusiveRange(limit - 100, limit),
          reason: 'precondition: just under the limit');

      await atServer.statsNotificationService
          .writeStatsToMonitor(latestCommitID: '7', operationType: 'update');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(first.metaData.isClosed, isTrue);
      expect(utf8.decode(secondReceived), contains('statsNotification'));
    });
  });
}
