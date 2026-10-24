import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/notification/monitor_sink.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/telemetry/notification_telemetry.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart'
    show AuthType, InboundConnection;
import 'package:at_telemetry/at_telemetry.dart' show AtTelemetryLogRecord;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'telemetry_test_support.dart';
import 'test_utils.dart';

/// Catalogue: features/monitor/monitor_feed.feature
void main() {
  late _InstrumentedMonitor monitor;
  late List<String> warnings;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    monitor = _InstrumentedMonitor(keyValueStore, notificationManager);
    warnings = <String>[];
    final Level priorLevel = monitor.logger.logger.level;
    monitor.logger.level = 'warning';
    final StreamSubscription<LogRecord> logs = monitor.logger.logger.onRecord
        .where((LogRecord record) => record.level == Level.WARNING)
        .listen((LogRecord record) => warnings.add(record.message));
    addTearDown(() async {
      await logs.cancel();
      monitor.logger.logger.level = priorLevel;
    });
  });

  tearDown(() async => await verbTestsTearDown());

  _RecordingConnection cramConnection() => _RecordingConnection()
    ..metadata.isAuthenticated = true
    ..metadata.authType = AuthType.cram
    ..metadata.sessionID = 'cram-session';

  _RecordingConnection apkamConnection(String enrollmentId) =>
      _RecordingConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.apkam
        ..metadata.enrollmentId = enrollmentId
        ..metadata.sessionID = 'apkam-session';

  Future<void> runMonitor(_RecordingConnection connection,
      [String command = 'monitor']) async {
    await monitor.processVerb(Response(), monitor.parse(command), connection);
  }

  AtNotification received(String id,
          {String key = '@alice:phone.wavi@bob', String from = '@bob'}) =>
      (AtNotificationBuilder()
            ..id = id
            ..fromAtSign = from
            ..toAtSign = alice
            ..notification = key
            ..notificationDateTime = DateTime.now()
            ..type = NotificationType.received)
          .build();

  Future<void> pushLive(AtNotification n) async {
    notificationManager.enqueue(n);
    await notificationManager.monitorsIdle;
  }

  test('A second monitor on a connection replaces the first', () async {
    final _RecordingConnection connection = cramConnection();
    await runMonitor(connection);

    await runMonitor(connection);
    await pushLive(received('n1'));

    expect(connection.ids, ['n1']);
    expect(notificationManager.monitorCount, 1);
  });

  test("The latest monitor's selfNotifications flag applies", () async {
    final _RecordingConnection connection = cramConnection();
    await runMonitor(connection, 'monitor:selfNotifications');
    AtNotification self(String id) => (AtNotificationBuilder()
          ..id = id
          ..fromAtSign = alice
          ..toAtSign = alice
          ..notification = 'phone.wavi'
          ..notificationDateTime = DateTime.now()
          ..type = NotificationType.self)
        .build();
    await pushLive(self('s0'));
    expect(connection.ids, ['s0'],
        reason: 'control: monitor:selfNotifications is written self ones');

    await runMonitor(connection);
    await pushLive(self('s1'));

    expect(connection.ids, ['s0']);
  });

  test('Pushes queued before a replacing monitor go out first, once', () async {
    final _RecordingConnection connection = cramConnection();
    await runMonitor(connection);
    final Completer<void> writing = connection.holdNextWrite();
    notificationManager.enqueue(received('n1'));
    await pumpEventQueue();

    final Future<void> replacing = runMonitor(connection);
    await pumpEventQueue();
    notificationManager.enqueue(received('n2'));
    await pumpEventQueue();
    expect(connection.ids, isEmpty, reason: 'n1 is still being written');
    writing.complete();
    await replacing;
    await notificationManager.monitorsIdle;

    expect(connection.ids, ['n1', 'n2']);
  });

  test('A monitor with an invalid regex leaves the existing feed as it was',
      () async {
    final _RecordingConnection connection = cramConnection();
    await runMonitor(connection, 'monitor wavi');

    await expectLater(
        monitor.processVerb(Response(),
            HashMap<String, String?>.of({AtConstants.regex: '['}), connection),
        throwsA(isA<InvalidSyntaxException>()
            .having((e) => e.message, 'message', 'Invalid regex: [')));
    await pushLive(received('n1'));

    expect(connection.ids, ['n1']);
  });

  test('Closing the connection ends its feed', () async {
    final _RecordingConnection connection = cramConnection();
    await runMonitor(connection);
    expect(notificationManager.monitorCount, 1, reason: 'control');

    connection.metadata.isClosed = true;
    await Future<void>.delayed(Duration.zero);

    expect(notificationManager.monitorCount, 0);
  });

  test('Live pushes reach a connection in the order they were queued',
      () async {
    final String enrollment =
        await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
    final _RecordingConnection connection = apkamConnection(enrollment);
    await runMonitor(connection);
    final Completer<void> slowLookup = monitor.holdNextLookup();

    notificationManager.enqueue(received('n1'));
    notificationManager.enqueue(received('n2'));
    await pumpEventQueue();
    expect(monitor.lookups, 1, reason: "n2's lookup waits behind n1's");
    slowLookup.complete();
    await notificationManager.monitorsIdle;

    expect(connection.ids, ['n1', 'n2']);
  });

  group('with a notification store whose reads can be held', () {
    late _GatedNotificationManager gated;

    setUp(() {
      gated = _GatedNotificationManager(
          alice, notifStore, notificationManager.notifyConnectionsPool);
      monitor = _InstrumentedMonitor(keyValueStore, gated);
    });

    tearDown(() async => await gated.close());

    test(
        'Given a replay of one sender\'s notification, when another sender\'s with the same id arrives live, then both are written',
        () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      await gated.notify(received('same'));
      final _RecordingConnection connection = cramConnection();
      final Completer<void> reading = gated.holdNextRead();

      final Future<void> monitoring = runMonitor(connection, 'monitor:$t');
      await pumpEventQueue();
      gated.enqueue(
          received('same', key: '@alice:phone.wavi@carol', from: '@carol'));
      reading.complete();
      await monitoring;
      await gated.monitorsIdle;

      expect([
        for (final String w in connection.writes)
          jsonDecode(w.substring('notification: '.length))['from'],
      ], [
        '@bob',
        '@carol'
      ]);
    });

    test(
        'Given a replay that is waiting on the store, when the connection closes, then a report waiting on its feed goes out at once',
        () async {
      final RecordingExporter exporter = RecordingExporter();
      enableRecording(serverTelemetry, exporter);
      final gatedWithTelemetry = _GatedNotificationManager(
          alice, notifStore, notificationManager.notifyConnectionsPool,
          telemetry: NotificationTelemetry(serverTelemetry));
      addTearDown(gatedWithTelemetry.close);
      monitor = _InstrumentedMonitor(keyValueStore, gatedWithTelemetry);
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      final _RecordingConnection connection = cramConnection();
      final Completer<void> reading = gatedWithTelemetry.holdNextRead();
      addTearDown(() {
        if (!reading.isCompleted) reading.complete();
      });
      unawaited(runMonitor(connection, 'monitor:$t'));
      await pumpEventQueue();
      gatedWithTelemetry.enqueue(received('n1'), report: true);

      connection.metadata.isClosed = true;
      final AtTelemetryLogRecord report = await exporter
          .firstNamed('atsign.atserver.notification.received')
          .timeout(const Duration(seconds: 2));

      expect(report.attributes['atsign.notification.push_count'], 0);
    });

    test(
        'Given a replay that is waiting on the store, when self notifications arrive for a feed without selfNotifications, then none is queued',
        () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      final _RecordingConnection connection = cramConnection();
      final Completer<void> reading = gated.holdNextRead();
      final Future<void> monitoring = runMonitor(connection, 'monitor:$t');
      await pumpEventQueue();

      for (int i = 0; i < 3; i++) {
        gated.enqueue(_self('s$i'));
      }
      expect(gated.queuedPushes, 0);
      gated.enqueue(received('n1'));
      expect(gated.queuedPushes, 1, reason: 'control: a received one is');

      reading.complete();
      await monitoring;
    });

    test('Replay is written before live pushes, each notification once',
        () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      await gated.notify(received('n1'));
      final _RecordingConnection connection = cramConnection();
      final Completer<void> reading = gated.holdNextRead();

      final Future<void> monitoring = runMonitor(connection, 'monitor:$t');
      await pumpEventQueue();
      await gated.notify(received('n2'));
      reading.complete();
      await monitoring;
      await gated.monitorsIdle;

      expect(connection.ids, ['n1', 'n2']);
    });

    test(
        'Replay matches the key only and live delivery matches the key or the sender',
        () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      await gated.notify(received('stored', key: '@alice:phone.buzz@bob'));
      final _RecordingConnection connection = cramConnection();

      await runMonitor(connection, 'monitor:$t ^bob');
      expect(connection.ids, isEmpty);

      gated.enqueue(received('live', key: '@alice:phone.buzz@bob'));
      await gated.monitorsIdle;
      expect(connection.ids, ['live']);
    });

    test('A replay that fails closes the connection', () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      gated.failNextRead(DataStoreException('notification store unavailable'));
      final _RecordingConnection connection = cramConnection();

      await monitor.process('monitor:$t', connection);
      await pumpEventQueue();

      expect(
          connection.writes.single,
          allOf(
              startsWith('error:'), contains('notification store unavailable')),
          reason: 'refused with the store error, written before the close');
      expect(connection.metadata.isClosed, isTrue);
      expect(gated.monitorCount, 0);
    });

    test(
        'Given a connection with a feed, when its monitor:<t> replay fails, then the connection is closed and leaves the pool',
        () async {
      final ServerSocket listener =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final Future<Socket> accepted = listener.first;
      final Socket client =
          await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
      addTearDown(client.destroy);
      final Socket serverSide = await accepted;
      await listener.close();
      client.listen((_) {}, onError: (Object _) {});
      atServer.inboundConnectionManager =
          InboundConnectionManager(serverAtSign: alice, poolSize: 3);
      final InboundConnection connection = atServer.inboundConnectionManager
          .createSocketConnection(serverSide, sessionId: 'failing-replay');
      addTearDown(connection.close);
      (connection.metaData as InboundConnectionMetadata)
        ..isAuthenticated = true
        ..authType = AuthType.cram;
      connection.acceptRequests((String command, InboundConnection c) async {});
      await monitor.process('monitor', connection);
      expect(gated.monitorCount, 1, reason: 'precondition: it has a feed');
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      gated.failNextRead(StateError('notification store closed'));

      Object? thrown;
      try {
        await monitor.process('monitor:$t', connection);
      } catch (e) {
        thrown = e;
      }
      for (int i = 0;
          i < 100 &&
              atServer.inboundConnectionManager.pool.getCurrentSize() > 0;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(connection.metaData.isClosed, isTrue,
          reason: 'a monitor whose replay fails closes its connection');
      expect(atServer.inboundConnectionManager.pool.getCurrentSize(), 0);
      expect(gated.monitorCount, 0);
      expect(thrown, isNull);
    });

    test(
        'Given a feed with a push queued, when a monitor:<t> that replaces it fails, then the earlier feed ends with the connection',
        () async {
      final Level priorLevel = monitor.logger.logger.level;
      monitor.logger.level = 'warning';
      final List<String> dropped = <String>[];
      final StreamSubscription<LogRecord> logs = monitor.logger.logger.onRecord
          .where((LogRecord record) => record.level == Level.WARNING)
          .listen((LogRecord record) => dropped.add(record.message));
      addTearDown(() async {
        await logs.cancel();
        monitor.logger.logger.level = priorLevel;
      });
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection);
      final Completer<void> writing = connection.holdNextWrite();
      gated.enqueue(received('n1'));
      await pumpEventQueue();
      gated.enqueue(received('n2'));
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      gated.failNextRead(DataStoreException('notification store unavailable'));

      await monitor.process('monitor:$t', connection);
      writing.complete();
      await pumpEventQueue();

      expect(connection.ids, ['n1'], reason: 'n1 was already being written');
      expect(
          dropped.single,
          allOf(contains('Dropped 1 queued notification'),
              contains('its monitor feed has ended')));
    });
  });

  test('A notification the client did not ask for causes no enrollment lookup',
      () async {
    final String enrollment =
        await createAndPersistAnEnrollment('chat', 'phone', {'buzz': 'rw'});
    final _RecordingConnection connection = apkamConnection(enrollment);
    await runMonitor(connection, 'monitor wavi');

    await pushLive(received('other', key: '@alice:phone.other@bob'));
    expect(monitor.lookups, 0);
    expect(warnings, isEmpty);

    await pushLive(received('asked', key: '@alice:phone.wavi@bob'));
    expect(monitor.lookups, 1,
        reason: 'control: a notification it asked for is looked up');
    expect(warnings, hasLength(1),
        reason: 'control: and refused with a warning');
  });

  test(
      "A push the connection's enrollment may not read is logged and not written",
      () async {
    final String enrollment =
        await createAndPersistAnEnrollment('chat', 'phone', {'buzz': 'rw'});
    final _RecordingConnection connection = apkamConnection(enrollment);
    await runMonitor(connection);

    await pushLive(received('n-11'));

    expect(connection.ids, isEmpty);
    expect(
        warnings.single,
        allOf([
          contains('n-11'),
          contains('@alice:phone.wavi@bob'),
          contains('apkam-session'),
          contains(enrollment),
          contains('not authorized'),
        ]));
  });

  test(
      'A push after the client re-authenticates is checked against the new enrollment',
      () async {
    final String e1 =
        await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
    final String e2 =
        await createAndPersistAnEnrollment('chat', 'tablet', {'buzz': 'rw'});
    final _RecordingConnection connection = apkamConnection(e1);
    await runMonitor(connection);
    await pushLive(received('before'));
    expect(connection.ids, ['before'], reason: 'control: e1 may read wavi');

    connection.metadata.enrollmentId = e2;
    await pushLive(received('after'));

    expect(connection.ids, ['before']);
  });

  test(
      'A push to a connection whose re-authentication failed is logged and not written',
      () async {
    final String e1 =
        await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
    final _RecordingConnection connection = apkamConnection(e1);
    await runMonitor(connection);
    await pushLive(received('before'));
    expect(connection.ids, ['before'], reason: 'control: e1 may read wavi');

    connection.metadata.isAuthenticated = false;
    await pushLive(received('after'));

    expect(connection.ids, ['before']);
    expect(
        warnings.single,
        allOf([
          contains('after'),
          contains('@alice:phone.wavi@bob'),
          contains('apkam-session'),
          contains(e1),
          contains('not authenticated'),
        ]));
  });

  test('Stats notifications still reach a monitor connection', () async {
    final _RecordingConnection connection = cramConnection();
    atServer.inboundConnectionManager =
        InboundConnectionManager(serverAtSign: alice, poolSize: 3);
    atServer.inboundConnectionManager.pool.add(connection);
    await runMonitor(connection, 'monitor nomatch');
    atServer.statsNotificationService.currentAtSign = alice;

    await atServer.statsNotificationService
        .writeStatsToMonitor(latestCommitID: '7', operationType: 'update');

    expect(connection.writes.single, contains('statsNotification.$alice'));
  });

  group('Given a monitor connection whose write fails', () {
    test('when a push is written, then the failure names its id and key',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection);
      final List<String> severe = <String>[];
      final StreamSubscription<LogRecord> logs = monitor.logger.logger.onRecord
          .where((LogRecord r) => r.level == Level.SEVERE)
          .listen((LogRecord r) => severe.add(r.message));
      addTearDown(logs.cancel);
      connection.failNextWrite = const SocketException('reset');

      await pushLive(received('n1'));

      expect(severe.single,
          allOf(contains('n1'), contains('@alice:phone.wavi@bob')));
    });
  });

  group('Given a monitor connection that is idle but still open', () {
    test('when a push is dropped, then the warning says it is idle or stale',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection);
      connection.idle = true;

      await pushLive(received('n1'));

      expect(connection.ids, isEmpty);
      expect(notificationManager.monitorCount, 1,
          reason: 'the feed stays, for when the client is active again');
      expect(warnings.single, contains('the connection is idle or stale'));
    });
  });

  group('Given a replay in which one enrollment read fails', () {
    test('when the replay runs, then it writes the others and the feed stays',
        () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      for (final String id in ['s1', 's2', 's3']) {
        await notificationManager.notify(received(id));
      }
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final _RecordingConnection connection = apkamConnection(e1);
      monitor.failEnrollmentReads(
          [null, DataStoreException('enrollment store unavailable')]);

      await runMonitor(connection, 'monitor:$t');
      await pushLive(received('live1'));

      expect(connection.ids, ['s1', 's3', 'live1']);
      expect(notificationManager.monitorCount, 1);
    });
  });

  group('Given stored self notifications', () {
    for (final (String command, List<String> replayed) in [
      ('monitor', <String>[]),
      ('monitor:selfNotifications', ['s1']),
    ]) {
      test(
          'when a client runs $command with an epoch, then it replays $replayed',
          () async {
        final int t = DateTime.now().millisecondsSinceEpoch - 1000;
        await notificationManager.notify(_self('s1'));
        final _RecordingConnection connection = cramConnection();

        await runMonitor(
            connection,
            command == 'monitor'
                ? 'monitor:$t'
                : 'monitor:selfNotifications:$t');

        expect(connection.ids, replayed);
      });
    }
  });

  group('Given a connection that has run monitor three times', () {
    test('when it closes, then its feed is removed once', () async {
      final _CountingNotificationManager counting =
          _CountingNotificationManager(
              alice, notifStore, notificationManager.notifyConnectionsPool);
      addTearDown(counting.close);
      monitor = _InstrumentedMonitor(keyValueStore, counting);
      final _RecordingConnection connection = cramConnection();
      for (int i = 0; i < 3; i++) {
        await runMonitor(connection);
      }

      connection.metadata.isClosed = true;
      await pumpEventQueue();

      expect(counting.removals, 1);
    });
  });

  group('Given a replay whose connection closes part way', () {
    test('when the replay goes on, then it logs no drop for the rest',
        () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      for (final String id in ['s1', 's2', 's3']) {
        await notificationManager.notify(received(id));
      }
      final _RecordingConnection connection = cramConnection();
      final Completer<void> writing = connection.holdNextWrite();

      final Future<void> monitoring = runMonitor(connection, 'monitor:$t');
      await pumpEventQueue();
      connection.metadata.isClosed = true;
      writing.complete();
      await monitoring;

      expect(connection.ids, ['s1']);
      expect(warnings, isEmpty);
    });
  });

  group('Given a push to a connection that has just closed', () {
    test(
        'when the feed drains it, then it is dropped without an enrollment lookup',
        () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final _RecordingConnection connection = apkamConnection(e1);
      await runMonitor(connection);

      notificationManager.enqueue(received('n1'));
      connection.metadata.isClosed = true;
      await pumpEventQueue();

      expect(monitor.lookups, 0);
      expect(warnings.single, contains('the connection is closed'));
    });
  });

  group('Given a monitor push whose enrollment read is in flight', () {
    late String e1;
    late _RecordingConnection connection;

    setUp(() async {
      e1 = await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      connection = apkamConnection(e1);
      await runMonitor(connection);
    });

    test(
        'when a pkam on the connection fails meanwhile, then the push is not written',
        () async {
      final Completer<void> read = monitor.holdNextEnrollmentRead();
      notificationManager.enqueue(received('n1'));
      await pumpEventQueue();

      connection.metadata.isAuthenticated = false;
      read.complete();
      await notificationManager.monitorsIdle;

      expect(connection.ids, isEmpty);
      expect(warnings.single, contains('the connection is not authenticated'));
    });

    test(
        'when the connection re-authenticates as an enrollment that may not read it, then the push is not written',
        () async {
      final String e2 =
          await createAndPersistAnEnrollment('chat', 'tablet', {'buzz': 'rw'});
      final Completer<void> read = monitor.holdNextEnrollmentRead();
      notificationManager.enqueue(received('n1'));
      await pumpEventQueue();

      connection.metadata.enrollmentId = e2;
      read.complete();
      await notificationManager.monitorsIdle;

      expect(connection.ids, isEmpty);
      expect(warnings.single,
          allOf(contains('enrollment $e2'), contains('not authorized')));
    });

    test(
        'when the connection re-authenticates as an enrollment that may read it, then it is reported under that enrollment',
        () async {
      final RecordingExporter exporter = RecordingExporter();
      enableRecording(serverTelemetry, exporter);
      final String e2 =
          await createAndPersistAnEnrollment('chat', 'tablet', {'wavi': 'rw'});
      final Completer<void> read = monitor.holdNextEnrollmentRead();
      notificationManager.enqueue(received('n1'), report: true);
      await pumpEventQueue();

      connection.metadata.enrollmentId = e2;
      read.complete();
      final AtTelemetryLogRecord report =
          await exporter.firstNamed('atsign.atserver.notification.received');

      expect(connection.ids, ['n1']);
      expect(report.attributes['atsign.notification.pushed_to'], [
        {'atsign.enrollment.id': e2},
      ]);
    });
  });

  group('Given fifty monitor feeds with telemetry on', () {
    test('when one received notification is reported, then it starts one timer',
        () async {
      enableRecording(serverTelemetry, RecordingExporter());
      bool counting = false;
      int timers = 0;

      await runZoned(() async {
        final NotificationManager manager = NotificationManager(
            alice, notifStore, notificationManager.notifyConnectionsPool,
            telemetry: NotificationTelemetry(serverTelemetry));
        monitor = _InstrumentedMonitor(keyValueStore, manager);
        for (int i = 0; i < 50; i++) {
          await runMonitor(cramConnection()..metadata.sessionID = 'session-$i');
        }
        counting = true;
        manager.enqueue(received('n1'), report: true);
        await manager.monitorsIdle;
        counting = false;
        await manager.close();
      }, zoneSpecification: ZoneSpecification(createTimer: (Zone self,
          ZoneDelegate parent,
          Zone zone,
          Duration duration,
          void Function() f) {
        if (counting) {
          timers++;
        }
        return parent.createTimer(zone, duration, f);
      }));

      expect(timers, 1, reason: "the report's timeout, and none per feed");
    });
  });

  group('Given a monitor feed with pushes queued when its connection closes',
      () {
    test(
        'when the queue drains, then one warning counts only the notifications it would have written',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection, 'monitor wavi');
      final Completer<void> writing = connection.holdNextWrite();
      notificationManager.enqueue(received('n0'));
      await pumpEventQueue();
      notificationManager.enqueue(received('n1'));
      notificationManager.enqueue(
          received('other-1', key: '@alice:phone.other@carol', from: '@carol'));
      notificationManager.enqueue(
          received('other-2', key: '@alice:phone.other@carol', from: '@carol'));

      connection.metadata.isClosed = true;
      await pumpEventQueue();
      writing.complete();
      await pumpEventQueue();

      expect(connection.ids, ['n0']);
      expect(warnings, [
        'Dropped 1 queued notification for session cram-session (CRAM):'
            ' its monitor feed has ended',
      ]);
    });
  });

  group('Given a monitor connection that closes during an enrollment lookup',
      () {
    test('when the lookup returns, then the push is not written or reported',
        () async {
      final RecordingExporter exporter = RecordingExporter();
      enableRecording(serverTelemetry, exporter);
      final String enrollment =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final _RecordingConnection connection = apkamConnection(enrollment);
      await runMonitor(connection);
      final Completer<void> lookup = monitor.holdNextLookup();
      notificationManager.enqueue(received('n1'), report: true);
      await pumpEventQueue();

      connection.metadata.isClosed = true;
      lookup.complete();
      final AtTelemetryLogRecord report =
          await exporter.firstNamed('atsign.atserver.notification.received');

      expect(report.attributes['atsign.notification.push_count'], 0);
      expect(connection.ids, isEmpty);
      expect(warnings, contains(contains('the connection is closed')));
    });
  });

  group('Given notifications a client missed while it was away', () {
    test(
        'when it runs monitor:<t>, then an ephemeral one still held is replayed and an expired one is not',
        () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      await notificationManager.notify(received('held'), ephemeral: true);
      await notificationManager.notify((AtNotificationBuilder()
            ..id = 'expired'
            ..fromAtSign = bob
            ..toAtSign = alice
            ..notification = '@alice:phone.wavi@bob'
            ..notificationDateTime = DateTime.now()
            ..expiresAt = DateTime.now().subtract(const Duration(seconds: 1))
            ..type = NotificationType.received)
          .build());
      final _RecordingConnection connection = cramConnection();

      await runMonitor(connection, 'monitor:$t');

      expect(connection.ids, ['held']);
      expect(warnings, isEmpty);
    });
  });

  group('Given a received notification a monitor would otherwise get', () {
    late RecordingExporter exporter;
    late List<String> severe;

    setUp(() {
      exporter = RecordingExporter();
      enableRecording(serverTelemetry, exporter);
      severe = <String>[];
      final StreamSubscription<LogRecord> logs = monitor.logger.logger.onRecord
          .where((LogRecord r) => r.level == Level.SEVERE)
          .listen((LogRecord r) => severe.add(r.message));
      addTearDown(logs.cancel);
    });

    /// Queues [n] for a report, as a peer's delivery does, and returns the
    /// report's attributes once the feeds have settled it.
    Future<Map<String, Object?>> deliver(AtNotification n) async {
      notificationManager.enqueue(n, report: true);
      await notificationManager.monitorsIdle;
      return (await exporter
              .firstNamed('atsign.atserver.notification.received')
              .timeout(const Duration(seconds: 2)))
          .attributes;
    }

    test(
        'when the connection is no longer authenticated, then it is not written, a warning names it, the connection and feed stay, and the report counts no push',
        () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final _RecordingConnection connection = apkamConnection(e1);
      await runMonitor(connection);
      connection.metadata.isAuthenticated = false;

      final Map<String, Object?> report = await deliver(received('missed'));

      expect(connection.ids, isEmpty);
      expect(warnings.single,
          allOf(contains('missed'), contains('not authenticated')));
      expect(severe, isEmpty);
      expect(connection.metadata.isClosed, isFalse);
      expect(notificationManager.monitorCount, 1);
      expect(report['atsign.notification.push_count'], 0);
      connection.metadata.isAuthenticated = true;
      await pushLive(received('next'));
      expect(connection.ids, ['next'],
          reason: 'the feed carries on once the connection may have it');
    });

    test(
        "when the connection's enrollment may not read it, then it is not written, a warning names it, the connection and feed stay, and the report counts no push",
        () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'buzz': 'rw'});
      final _RecordingConnection connection = apkamConnection(e1);
      await runMonitor(connection);

      final Map<String, Object?> report = await deliver(received('missed'));

      expect(connection.ids, isEmpty);
      expect(warnings.single,
          allOf(contains('missed'), contains('not authorized')));
      expect(severe, isEmpty);
      expect(connection.metadata.isClosed, isFalse);
      expect(notificationManager.monitorCount, 1);
      expect(report['atsign.notification.push_count'], 0);
      await pushLive(received('next', key: '@alice:phone.buzz@bob'));
      expect(connection.ids, ['next'],
          reason: 'the feed carries on with what the enrollment may read');
    });

    test(
        'when the connection is idle or stale, then it is not written, a warning says so, the connection and feed stay, and delivery resumes once it is active',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection);
      connection.idle = true;

      final Map<String, Object?> report = await deliver(received('missed'));

      expect(connection.ids, isEmpty);
      expect(
          warnings.single,
          allOf(
              contains('missed'), contains('the connection is idle or stale')));
      expect(severe, isEmpty);
      expect(connection.metadata.isClosed, isFalse);
      expect(notificationManager.monitorCount, 1);
      expect(report['atsign.notification.push_count'], 0);
      connection.idle = false;
      await pushLive(received('next'));
      expect(connection.ids, ['next']);
    });

    test(
        'when looking up the enrollment fails, then it is not written, a severe line names it and the connection, the feed stays, and the next is written',
        () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final _RecordingConnection connection = apkamConnection(e1);
      await runMonitor(connection);
      monitor.failEnrollmentReads(
          [DataStoreException('enrollment store unavailable')]);

      final Map<String, Object?> report = await deliver(received('missed'));

      expect(connection.ids, isEmpty);
      expect(
          severe.single,
          allOf(
              contains('enrollment store unavailable'),
              contains(
                  'while looking up the enrollment for notification missed'),
              contains('apkam-session')));
      expect(warnings, isEmpty);
      expect(connection.metadata.isClosed, isFalse);
      expect(notificationManager.monitorCount, 1);
      expect(report['atsign.notification.push_count'], 0);
      await pushLive(received('next'));
      expect(connection.ids, ['next']);
    });

    test(
        'when it has expired by the time it is written, then it is not written, a warning says so, and the feed stays',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection);

      final Map<String, Object?> report = await deliver((AtNotificationBuilder()
            ..id = 'missed'
            ..fromAtSign = bob
            ..toAtSign = alice
            ..notification = '@alice:phone.wavi@bob'
            ..notificationDateTime = DateTime.now()
            ..expiresAt = DateTime.now().subtract(const Duration(seconds: 1))
            ..type = NotificationType.received)
          .build());

      expect(connection.ids, isEmpty);
      expect(warnings.single,
          allOf(contains('missed'), contains('it has expired')));
      expect(severe, isEmpty);
      expect(connection.metadata.isClosed, isFalse);
      expect(notificationManager.monitorCount, 1);
      expect(report['atsign.notification.push_count'], 0);
      await pushLive(received('next'));
      expect(connection.ids, ['next']);
    });

    test(
        'when writing it to the connection fails, then a severe line names it, the feed stays, and the next is written',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection);
      connection.failNextWrite = const SocketException('reset');

      final Map<String, Object?> report = await deliver(received('missed'));

      expect(connection.ids, isEmpty);
      expect(
          severe.single,
          allOf(
              contains('reset'),
              contains('while delivering notification missed'),
              contains('@alice:phone.wavi@bob')));
      expect(warnings, isEmpty);
      expect(notificationManager.monitorCount, 1);
      expect(report['atsign.notification.push_count'], 0);
      await pushLive(received('next'));
      expect(connection.ids, ['next']);
    });

    test(
        'when its key and sender do not match the regex, then it is not written, nothing is logged and no enrollment is looked up',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection, 'monitor buzz');

      final Map<String, Object?> report = await deliver(received('missed'));

      expect(connection.ids, isEmpty);
      expect(monitor.lookups, 0);
      expect(warnings, isEmpty);
      expect(severe, isEmpty);
      expect(notificationManager.monitorCount, 1);
      expect(report['atsign.notification.push_count'], 0);
      await pushLive(received('next', key: '@alice:phone.buzz@bob'));
      expect(connection.ids, ['next']);
    });

    test(
        'when it is a self notification and the monitor did not ask for them, then it is not written and nothing is logged',
        () async {
      final _RecordingConnection connection = cramConnection();
      await runMonitor(connection);

      await pushLive(_self('missed'));

      expect(connection.ids, isEmpty);
      expect(warnings, isEmpty);
      expect(severe, isEmpty);
      expect(notificationManager.monitorCount, 1);
      await pushLive(received('next'));
      expect(connection.ids, ['next']);
    });
  });
}

/// A connection that keeps every write, and can hold its next write.
class _RecordingConnection extends DummyInboundConnection {
  final List<String> writes = <String>[];
  Completer<void>? _hold;

  /// The ids of the notifications written to this connection, in order.
  List<Object?> get ids => [
        for (final String w in writes)
          if (w.startsWith('notification: '))
            jsonDecode(w.substring('notification: '.length))['id'],
      ];

  /// Holds the next write until the returned completer completes.
  Completer<void> holdNextWrite() => _hold = Completer<void>();

  /// Whether the connection reports itself invalid while still open, as an
  /// idle or stale one does.
  bool idle = false;

  /// What the next write throws, if anything.
  Exception? failNextWrite;

  @override
  bool isInValid() => idle || super.isInValid();

  @override
  Future<void> close() async {
    metadata.isClosed = true;
  }

  @override
  Future<void> write(String data) async {
    final Exception? failure = failNextWrite;
    failNextWrite = null;
    if (failure != null) {
      throw failure;
    }
    final Completer<void>? hold = _hold;
    _hold = null;
    if (hold != null) {
      await hold.future;
    }
    writes.add(data);
    lastWrittenData = data;
  }
}

/// A monitor handler that counts its enrollment lookups and can hold the
/// next one.
class _InstrumentedMonitor extends MonitorVerbHandler {
  _InstrumentedMonitor(super.keyStore, super.notifMgr);

  int lookups = 0;
  Completer<void>? _hold;
  Completer<void>? _holdRead;

  /// Holds the next lookup until the returned completer completes.
  Completer<void> holdNextLookup() => _hold = Completer<void>();

  final List<Exception?> _readFailures = <Exception?>[];

  /// Makes the enrollment reads fail in turn with [failures]: null lets that
  /// read through.
  void failEnrollmentReads(List<Exception?> failures) =>
      _readFailures.addAll(failures);

  /// Holds the next enrollment read, after the lookup has read which
  /// enrollment the connection stands on, until the returned completer
  /// completes.
  Completer<void> holdNextEnrollmentRead() => _holdRead = Completer<void>();

  @override
  Future<EnrollDataStoreValue?> resolveEnrollment(String enrollmentId) async {
    if (_readFailures.isNotEmpty) {
      final Exception? failure = _readFailures.removeAt(0);
      if (failure != null) {
        throw failure;
      }
    }
    final Completer<void>? hold = _holdRead;
    _holdRead = null;
    if (hold != null) {
      await hold.future;
    }
    return super.resolveEnrollment(enrollmentId);
  }

  @override
  Future<bool> isAuthorized(InboundConnectionMetadata inboundConnectionMetadata,
      {String? atKey,
      String? namespace,
      String enrolledNamespaceAccess = '',
      String operation = ''}) async {
    lookups++;
    final Completer<void>? hold = _hold;
    _hold = null;
    if (hold != null) {
      await hold.future;
    }
    return super.isAuthorized(inboundConnectionMetadata,
        atKey: atKey,
        namespace: namespace,
        enrolledNamespaceAccess: enrolledNamespaceAccess,
        operation: operation);
  }
}

/// A self notification from @alice to herself.
AtNotification _self(String id) => (AtNotificationBuilder()
      ..id = id
      ..fromAtSign = alice
      ..toAtSign = alice
      ..notification = 'phone.wavi'
      ..notificationDateTime = DateTime.now()
      ..type = NotificationType.self)
    .build();

/// A NotificationManager that counts the monitor feeds it removes.
class _CountingNotificationManager extends NotificationManager {
  _CountingNotificationManager(
      super.atSign, super.notifStore, super.notifyConnectionsPool);

  int removals = 0;

  @override
  void removeMonitor(InboundConnection connection, {MonitorSink? only}) {
    removals++;
    super.removeMonitor(connection, only: only);
  }
}

/// A NotificationManager whose next store read can be held, or made to fail.
class _GatedNotificationManager extends NotificationManager {
  _GatedNotificationManager(
      super.atSign, super.notifStore, super.notifyConnectionsPool,
      {super.telemetry});

  Completer<void>? _hold;
  Object? _failure;

  /// Holds the next read until the returned completer completes.
  Completer<void> holdNextRead() => _hold = Completer<void>();

  /// Makes the next read throw [failure].
  void failNextRead(Object failure) => _failure = failure;

  @override
  Future<List<AtNotification>> getFilteredSorted({
    required bool Function(AtNotification) retain,
    required int Function(AtNotification, AtNotification)? comparator,
  }) async {
    final Object? failure = _failure;
    _failure = null;
    if (failure != null) {
      throw failure;
    }
    final Completer<void>? hold = _hold;
    _hold = null;
    if (hold != null) {
      await hold.future;
    }
    return super.getFilteredSorted(retain: retain, comparator: comparator);
  }
}
