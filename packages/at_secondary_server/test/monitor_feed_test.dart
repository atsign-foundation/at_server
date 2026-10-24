import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
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

    test('A replay that fails leaves no feed behind', () async {
      final int t = DateTime.now().millisecondsSinceEpoch - 1000;
      final DataStoreException unavailable =
          DataStoreException('notification store unavailable');
      gated.failNextRead(unavailable);
      final _RecordingConnection connection = cramConnection();

      await expectLater(
          runMonitor(connection, 'monitor:$t'), throwsA(same(unavailable)));
      gated.enqueue(received('n1'));
      await gated.monitorsIdle;

      expect(gated.monitorCount, 0);
      expect(connection.ids, isEmpty);
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

  @override
  Future<void> write(String data) async {
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

  /// Holds the next lookup until the returned completer completes.
  Completer<void> holdNextLookup() => _hold = Completer<void>();

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

/// A NotificationManager whose next store read can be held, or made to fail.
class _GatedNotificationManager extends NotificationManager {
  _GatedNotificationManager(
      super.atSign, super.notifStore, super.notifyConnectionsPool);

  Completer<void>? _hold;
  Exception? _failure;

  /// Holds the next read until the returned completer completes.
  Completer<void> holdNextRead() => _hold = Completer<void>();

  /// Makes the next read throw [failure].
  void failNextRead(Exception failure) => _failure = failure;

  @override
  Future<List<AtNotification>> getFilteredSorted({
    required bool Function(AtNotification) retain,
    required int Function(AtNotification, AtNotification)? comparator,
  }) async {
    final Exception? failure = _failure;
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
