import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/notification/monitor_sink.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/notification_telemetry.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart'
    show AtConnectionMetaData, AuthType, InboundConnection;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart' show Fake;
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'telemetry_test_support.dart';
import 'test_utils.dart';

/// Peers' notifications delivered through the listener every inbound
/// connection runs, in the guarded zone it gives that connection.
void main() {
  final Duration defaultTimeout = NotificationManager.livePushTimeout;
  final Atsign carol = '@carol'.toAtsign();
  late _ReportTelemetry telemetry;
  late NotificationManager manager;
  late NotifyVerbHandler notify;
  late List<Object> monitorZoneErrors;

  String peerNotify(String id, {Atsign? from}) =>
      'notify:id:$id:update:messageType:key:ttln:60000'
      ':@alice:phone.wavi${from ?? bob}:v';

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await setUpAtSignBound();
    enableRecording(serverTelemetry, RecordingExporter());
    telemetry = _ReportTelemetry(serverTelemetry);
    manager = runZoned(
        () => NotificationManager(
            alice, notifStore, notificationManager.notifyConnectionsPool,
            telemetry: telemetry),
        zoneValues: {#owner: 'manager'});
    notify = NotifyVerbHandler(keyValueStore, manager);
    monitorZoneErrors = <Object>[];
  });

  tearDown(() async {
    NotificationManager.livePushTimeout = defaultTimeout;
    await manager.close();
    await verbTestsTearDown();
  });

  /// Runs `monitor` on [connection] in a zone of its own, named [owner], as
  /// its own listener would.
  Future<void> monitorOn(_Monitor connection, {String command = 'monitor'}) {
    final MonitorVerbHandler handler =
        MonitorVerbHandler(keyValueStore, manager);
    final Completer<void> done = Completer<void>();
    runZonedGuarded(() async {
      await handler.processVerb(Response(), handler.parse(command), connection);
      done.complete();
    }, (Object e, StackTrace _) => monitorZoneErrors.add(e),
        zoneValues: {#owner: connection.metadata.sessionID});
    return done.future;
  }

  void expectNothingEscaped(List<_Peer> peers) {
    for (final _Peer peer in peers) {
      expect(peer.connection.closeCount, 0,
          reason: '${peer.name} keeps its connection');
      expect(peer.zoneErrors, isEmpty,
          reason: "nothing reaches ${peer.name}'s connection zone");
      expect(peer.escaped, isEmpty);
    }
    expect(monitorZoneErrors, isEmpty);
  }

  test(
      'Given no monitor, when a peer delivers a notification whose report fails, then the peer is answered data:success, keeps its connection, nothing reaches a zone, and its next notification is answered too',
      () async {
    telemetry.failsOn = (AtNotification n) => n.id == 'n1';
    final _Peer peer = _Peer.listen('bob', bob, notify);

    await peer.send(peerNotify('n1'));
    await peer.send(peerNotify('n2'));
    await pumpEventQueue();

    expect(
        peer.connection.writes, ['data:success\n@bob@', 'data:success\n@bob@']);
    expectNothingEscaped([peer]);
    expect(telemetry.reportedIn, ['manager', 'manager'],
        reason: "each report is sent from the manager's zone");
  });

  test(
      "Given a monitor whose first write is held, when one peer's notification wakes its feed and another peer's report fails as the feed settles it, then both are answered data:success, no connection is closed, nothing reaches a zone, and the feed goes on writing",
      () async {
    final _Monitor monitor = _Monitor('monitor-a')..holdFirstWrite();
    await monitorOn(monitor);
    telemetry.failsOn = (AtNotification n) => n.id == 'n2';
    final _Peer first = _Peer.listen('bob', bob, notify);
    final _Peer second = _Peer.listen('carol', carol, notify);

    await first.send(peerNotify('n1'));
    await second.send(peerNotify('n2', from: carol));
    monitor.releaseFirstWrite();
    await manager.monitorsIdle;
    await second.send(peerNotify('n3', from: carol));
    await manager.monitorsIdle;
    final bool replaced = await monitorOn(monitor)
        .then((_) => true)
        .timeout(const Duration(seconds: 1), onTimeout: () => false);

    expect(first.connection.writes, ['data:success\n@bob@']);
    expect(second.connection.writes,
        ['data:success\n@carol@', 'data:success\n@carol@']);
    expectNothingEscaped([first, second]);
    expect(monitor.ids, ['n1', 'n2', 'n3']);
    expect(replaced, isTrue, reason: 'a replacing monitor is not held up');
  });

  test(
      "Given a monitor that never writes, when a peer's notification's report fails as it times out, then the peer keeps its connection and nothing reaches a zone",
      () async {
    NotificationManager.livePushTimeout = const Duration(milliseconds: 100);
    await monitorOn(_Monitor('monitor-a')..neverWrite());
    telemetry.failsOn = (AtNotification n) => true;
    final _Peer peer = _Peer.listen('bob', bob, notify);

    await peer.send(peerNotify('n1'));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(peer.connection.writes, ['data:success\n@bob@']);
    expectNothingEscaped([peer]);
    expect(telemetry.reportedIn, ['manager'],
        reason: "the report's timer runs in the manager's zone");
  });

  test(
      'Given the stats service is off, when a peer delivers a notification with ttr, then it is answered data:success, keeps its connection, nothing reaches a zone, the cached key is written, and its next notification is answered too',
      () async {
    expect(atServer.statsNotificationService.currentAtSign, isNull,
        reason: 'precondition: the stats service was never scheduled');
    final _PooledPeer connection = _PooledPeer(bob);
    atServer.inboundConnectionManager.pool.add(connection);
    final _Peer peer = _Peer.listen('bob', bob, notify, connection: connection);
    String withTtr(String id) =>
        'notify:id:$id:update:messageType:key:ttln:60000:ttr:-1'
        ':@alice:phone.wavi@bob:v';

    await peer.send(withTtr('n1'));
    await peer.send(withTtr('n2'));
    await pumpEventQueue();

    expect(
        peer.connection.writes, ['data:success\n@bob@', 'data:success\n@bob@']);
    expectNothingEscaped([peer]);
    expect(await keyValueStore.exists('cached:@alice:phone.wavi@bob'), isTrue);
  });

  test(
      "Given the stats service is off, when the atSign's own client updates a key, then it is answered once, with the commit id",
      () async {
    atServer.inboundConnectionManager.pool.add(_PooledPeer(bob));
    final UpdateVerbHandler update = UpdateVerbHandler(
        keyValueStore, atServer.statsNotificationService, manager, alice);
    final Connection client = aliceClient();

    await _serve(update, 'update:@bob:phone.wavi@alice v', client);

    expect(client.writes, [matches(RegExp(r'^data:\d+\n@alice@$'))]);
  });

  test(
      'Given the stats service is on and writing stats fails, when a peer delivers a notification with ttr, then it is answered data:success, keeps its connection and nothing reaches a zone',
      () async {
    atServer.statsNotificationService.currentAtSign = alice;
    addTearDown(() => atServer.statsNotificationService.currentAtSign = null);
    final _PooledPeer connection = _PooledPeer(bob);
    atServer.inboundConnectionManager.pool.add(connection);
    atServer.inboundConnectionManager.pool.add(peer(carol));
    final _Peer listening =
        _Peer.listen('bob', bob, notify, connection: connection);

    await listening.send('notify:id:n1:update:messageType:key:ttln:60000'
        ':ttr:-1:@alice:phone.wavi@bob:v');
    await pumpEventQueue();

    expect(listening.connection.writes, ['data:success\n@bob@']);
    expectNothingEscaped([listening]);
  });

  test(
      "Given a monitor connection whose metadata is not an inbound connection's, when a peer's notification is pushed to it, then the peer keeps its connection, nothing reaches a zone, and the other monitor is still written it",
      () async {
    final MonitorVerbHandler handler =
        MonitorVerbHandler(keyValueStore, manager);
    await runZonedGuarded(
        () => handler.processVerb(
            Response(), handler.parse('monitor'), _PlainMonitor()),
        (Object e, StackTrace _) => monitorZoneErrors.add(e),
        zoneValues: {#owner: 'plain'});
    final _Monitor monitor = _Monitor('monitor-a');
    await monitorOn(monitor);
    final _Peer peer = _Peer.listen('bob', bob, notify);

    await peer.send(peerNotify('n1'));
    await peer.send(peerNotify('n2'));
    await manager.monitorsIdle;
    await pumpEventQueue();

    expect(
        peer.connection.writes, ['data:success\n@bob@', 'data:success\n@bob@']);
    expectNothingEscaped([peer]);
    expect(monitor.ids, ['n1', 'n2']);
  });

  test(
      "Given a monitor, when a peer's notification is pushed to it, then the monitor's write runs in the monitor connection's zone and the report in the manager's",
      () async {
    final _Monitor monitor = _Monitor('monitor-a');
    await monitorOn(monitor);
    final _Peer peer = _Peer.listen('bob', bob, notify);

    await peer.send(peerNotify('n1'));
    await manager.monitorsIdle;
    await pumpEventQueue();

    expect(monitor.ids, ['n1']);
    expect(monitor.writtenIn, ['monitor-a']);
    expect(telemetry.reportedIn, ['manager']);
    expectNothingEscaped([peer]);
  });
}

/// A peer connection the inbound pool can hold, as it holds every inbound
/// connection.
class _PooledPeer extends Connection {
  _PooledPeer(Atsign atSign) : super(peer(atSign).metaData);

  bool? _isMonitor = false;

  @override
  bool? get isMonitor => _isMonitor;

  @override
  set isMonitor(bool? value) => _isMonitor = value;
}

/// A monitor connection whose metadata is not an inbound connection's.
class _PlainMonitor extends Fake implements InboundConnection {
  final AtConnectionMetaData _metaData = _PlainMetaData()
    ..isAuthenticated = true
    ..sessionID = 'plain';

  @override
  AtConnectionMetaData get metaData => _metaData;

  @override
  bool? isMonitor;

  @override
  bool isInValid() => false;

  @override
  Future<void> write(String data) async {}

  @override
  Future<void> close() async {}
}

class _PlainMetaData extends AtConnectionMetaData {}

/// A peer connection served by the real [InboundMessageListener], so each
/// command runs in the guarded zone the atServer gives the connection.
class _Peer {
  _Peer._(this.name, this.connection);

  /// Listens on a connection [from] has proved itself on by pol, or on
  /// [connection], sending its notifications to [notify] as the atServer's
  /// callback does.
  factory _Peer.listen(String name, Atsign from, AbstractVerbHandler notify,
      {Connection? connection}) {
    final _Peer listening = _Peer._(name, connection ?? peer(from));
    final InboundMessageListener listener =
        InboundMessageListener(listening.connection);
    listener.logger.level = 'warning';
    listener.logger.logger.onRecord
        .where((LogRecord r) =>
            r.message.startsWith('runZonedGuarded received error'))
        .listen((LogRecord r) => listening.zoneErrors.add(r.message));
    runZonedGuarded(
        () => listener.listen((String command, InboundConnection c) =>
            _serve(notify, command, c)),
        (Object e, StackTrace _) => listening.escaped.add(e));
    return listening;
  }

  final String name;
  final Connection connection;

  /// What the connection's zone handler logged before closing it.
  final List<String> zoneErrors = <String>[];

  /// What got past the connection's zone handler.
  final List<Object> escaped = <Object>[];

  /// Sends [command] and waits for its answer.
  Future<void> send(String command) async {
    final int before = connection.writes.length;
    connection.socket.addData('$command\n');
    for (int i = 0; i < 500 && connection.writes.length == before; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(connection.writes.length, before + 1,
        reason: 'precondition: $name was answered');
    await pumpEventQueue();
  }
}

/// Answers [command] on [connection] as the atServer's callback does: what
/// [handler] throws is answered by [GlobalExceptionHandler], an [Error] as an
/// [InternalServerError].
Future<void> _serve(AbstractVerbHandler handler, String command,
    InboundConnection connection) async {
  try {
    await handler.process(command, connection);
  } on Exception catch (e, st) {
    await GlobalExceptionHandler.getInstance()
        .handle(e, stackTrace: st, atConnection: connection);
  } on Error catch (e, st) {
    await GlobalExceptionHandler.getInstance().handle(
        InternalServerError(e.toString()),
        stackTrace: st,
        atConnection: connection);
  }
}

/// A CRAM monitor connection that records what it is written and the zone
/// each write runs in.
class _Monitor extends DummyInboundConnection {
  _Monitor(String session) {
    metadata
      ..isAuthenticated = true
      ..authType = AuthType.cram
      ..sessionID = session;
  }

  final List<String> _writes = <String>[];

  /// The owner of the zone each write ran in.
  final List<Object?> writtenIn = <Object?>[];

  Completer<void>? _hold;
  bool _neverWrite = false;

  void holdFirstWrite() => _hold = Completer<void>();

  void releaseFirstWrite() => _hold?.complete();

  void neverWrite() => _neverWrite = true;

  /// The ids of the notifications written, in order.
  List<Object?> get ids => [
        for (final String w in _writes)
          if (w.startsWith('notification: '))
            RegExp(r'"id":"([^"]*)"').firstMatch(w)?.group(1),
      ];

  @override
  Future<void> write(String data) async {
    writtenIn.add(Zone.current[#owner]);
    if (_neverWrite) {
      return Completer<void>().future;
    }
    final Completer<void>? hold = _hold;
    if (hold != null && _writes.isEmpty) {
      await hold.future;
    }
    _writes.add(data);
  }
}

/// Reports through [AtServerTelemetry], recording the zone each
/// notification.received report is sent from, and failing on the
/// notifications [failsOn] picks.
final class _ReportTelemetry extends NotificationTelemetry {
  _ReportTelemetry(AtServerTelemetry super.telemetry);

  bool Function(AtNotification n) failsOn = (AtNotification n) => false;

  /// The owner of the zone each report was sent from.
  final List<Object?> reportedIn = <Object?>[];

  @override
  void received(AtNotification n,
      {List<LivePush> pushedTo = const <LivePush>[]}) {
    reportedIn.add(Zone.current[#owner]);
    if (failsOn(n)) {
      throw StateError('the report on ${n.id} failed');
    }
    super.received(n, pushedTo: pushedTo);
  }
}
