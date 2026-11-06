import 'dart:async';
import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart'
    as exception_handler;
import 'package:at_secondary/src/notification/monitor_sink.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/telemetry/notification_telemetry.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart'
    show AuthType, InboundConnection;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'telemetry_test_support.dart';
import 'test_utils.dart';

void main() {
  late RecordingExporter exporter;
  late List<LogRecord> handlerLogs;

  String peerNotify(String id) =>
      'notify:id:$id:update:messageType:key:ttln:60000:@alice:phone.wavi@bob:v';

  Future<List<String>> storedIds() async =>
      [await for (final n in notifStore.iterate()) n.id!];

  Future<DummyInboundConnection> monitorOn(NotificationManager manager) async {
    final DummyInboundConnection connection = DummyInboundConnection();
    connection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    await MonitorVerbHandler(keyValueStore, manager)
        .processVerb(Response(), HashMap<String, String?>(), connection);
    return connection;
  }

  /// Sends [command] on [connection] to [handler] as the atServer does: what
  /// it throws is answered by GlobalExceptionHandler, an [Error] as an
  /// [InternalServerError].
  Future<void> sendTo(AbstractVerbHandler handler, String command,
      Connection connection) async {
    try {
      await handler.process(command, connection);
    } on Exception catch (e) {
      await exception_handler.GlobalExceptionHandler.getInstance()
          .handle(e, atConnection: connection);
    } on Error catch (e) {
      await exception_handler.GlobalExceptionHandler.getInstance()
          .handle(InternalServerError(e.toString()), atConnection: connection);
    }
  }

  setUpAll(() async {
    await verbTestsSetUpAll();
    registerFallbackValue(AtNotificationBuilder().build());
  });

  setUp(() async {
    await setUpAtSignBound();
    exporter = RecordingExporter();
    enableRecording(serverTelemetry, exporter);
    handlerLogs = <LogRecord>[];
    final Level prior = exception_handler.logger.logger.level;
    exception_handler.logger.level = 'info';
    final StreamSubscription<LogRecord> logs =
        exception_handler.logger.logger.onRecord.listen(handlerLogs.add);
    addTearDown(() async {
      await logs.cancel();
      exception_handler.logger.logger.level = prior;
    });
  });

  tearDown(() async => await verbTestsTearDown());

  test(
      'Given a peer delivering a notification, when the notification store cannot store it, then the peer is answered with the store error and its connection closed, nothing is pushed or reported, and a later delivery is stored and pushed',
      () async {
    final MockAtNotificationKeystore store = MockAtNotificationKeystore();
    int puts = 0;
    when(() => store.put(any(), any(), skipCommit: any(named: 'skipCommit')))
        .thenAnswer((_) async {
      if (puts++ == 0) {
        throw DataStoreException('notification store is full');
      }
      return null;
    });
    when(() => store.exists(any())).thenAnswer((_) async => false);
    final NotificationManager manager = NotificationManager(
        alice, store, MockNotifyConnectionsPool(),
        telemetry: NotificationTelemetry(serverTelemetry));
    addTearDown(manager.close);
    final NotifyVerbHandler notify = NotifyVerbHandler(keyValueStore, manager);
    final DummyInboundConnection monitoring = await monitorOn(manager);
    final Connection first = peer(bob);

    await sendTo(notify, peerNotify('n1'), first);
    await pumpEventQueue();

    expect(first.writes, ['error:AT0002-notification store is full\n@']);
    expect(first.closeCount, 1);
    expect(
        handlerLogs
            .where((LogRecord r) => r.level == Level.SHOUT)
            .single
            .message,
        contains('notification store is full'));
    expect(monitoring.lastWrittenData, isNull);
    expect(
        eventNames(exporter.records,
            prefix: 'atsign.atserver.notification.received'),
        isEmpty);

    final Connection retry = peer(bob);
    await sendTo(notify, peerNotify('n1'), retry);
    await manager.monitorsIdle;

    expect(retry.writes, ['data:success\n@bob@']);
    expect(monitoring.lastWrittenData, contains('"id":"n1"'),
        reason: 'the atServer carries on, and the retry is stored and pushed');
  });

  test(
      'Given a feed that throws when handed a notification, when a peer delivers one, then the peer is answered data:success, the other feeds get it, one severe line names it, and the report is not held',
      () async {
    final DummyInboundConnection before = await monitorOn(notificationManager);
    notificationManager.addMonitor(_ThrowingSink(
        DummyInboundConnection()..metadata.sessionID = 'broken-session'));
    final DummyInboundConnection after = await monitorOn(notificationManager);
    final Level prior = notificationManager.logger.logger.level;
    notificationManager.logger.level = 'warning';
    final List<String> severe = <String>[];
    final StreamSubscription<LogRecord> logs = notificationManager
        .logger.logger.onRecord
        .where((LogRecord r) => r.level == Level.SEVERE)
        .listen((LogRecord r) => severe.add(r.message));
    addTearDown(() async {
      await logs.cancel();
      notificationManager.logger.logger.level = prior;
    });
    final Connection first = peer(bob);

    await send(peerNotify('n1'), first);
    await notificationManager.monitorsIdle;

    expect(first.writes, ['data:success\n@bob@']);
    expect(first.closeCount, 0);
    expect(handlerLogs, isEmpty, reason: 'nothing reaches the sender');
    expect(
        severe.single,
        allOf(contains('feed broke'), contains('notification n1'),
            contains('@alice:phone.wavi@bob'), contains('broken-session')));
    expect(await storedIds(), ['n1']);
    expect(before.lastWrittenData, contains('"id":"n1"'));
    expect(after.lastWrittenData, contains('"id":"n1"'));
    final Map<String, Object?> report = (await exporter
            .firstNamed('atsign.atserver.notification.received')
            .timeout(const Duration(seconds: 2),
                onTimeout: () => fail('the report waited for the feed that '
                    'failed instead of going out once the others settled')))
        .attributes;
    expect(report['atsign.notification.ids'], ['n1']);
  });

  test(
      'Given the notification manager closes while a peer delivery is being stored, when the store finishes, then the peer is answered with an internal error and no monitor is pushed it',
      () async {
    final MockAtNotificationKeystore store = MockAtNotificationKeystore();
    final Completer<void> storing = Completer<void>();
    when(() => store.put(any(), any(), skipCommit: any(named: 'skipCommit')))
        .thenAnswer((_) => storing.future.then((_) => null));
    when(() => store.exists(any())).thenAnswer((_) async => false);
    final NotificationManager manager = NotificationManager(
        alice, store, MockNotifyConnectionsPool(),
        telemetry: NotificationTelemetry(serverTelemetry));
    final NotifyVerbHandler notify = NotifyVerbHandler(keyValueStore, manager);
    final DummyInboundConnection monitoring = await monitorOn(manager);
    final Connection first = peer(bob);

    final Future<void> delivering = sendTo(notify, peerNotify('n1'), first);
    await pumpEventQueue();
    await manager.close();
    storing.complete();
    await delivering;

    expect(first.writes, ['error:AT0010-Exception: Bad state: Closed\n@']);
    expect(first.closeCount, 0);
    expect(monitoring.lastWrittenData, isNull);
  });
}

/// A monitor feed whose push throws after it has counted itself in the report.
class _ThrowingSink implements MonitorSink {
  _ThrowingSink(this.connection);

  @override
  final InboundConnection connection;

  @override
  void push(AtNotification n, {LivePushReport? report}) {
    report?.expect();
    throw StateError('feed broke');
  }

  @override
  Future<void> get idle => Future<void>.value();

  @override
  int get queued => 0;

  @override
  void close() {}
}
