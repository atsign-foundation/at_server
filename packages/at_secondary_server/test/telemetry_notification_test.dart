import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart'
    show OutboundClient;
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_telemetry/at_telemetry.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late List<AtTelemetryLogRecord> records;

  List<AtTelemetryLogRecord> notificationEvents() {
    return records
        .where((AtTelemetryLogRecord record) => record.eventName!
            .startsWith('$atServerTelemetryEventPrefix.notification.'))
        .toList();
  }

  List<String?> names() {
    return notificationEvents()
        .map((AtTelemetryLogRecord record) => record.eventName)
        .toList();
  }

  setUpAll(() {
    registerFallbackValue(AtNotificationBuilder().build());
  });

  setUp(() {
    records = <AtTelemetryLogRecord>[];
  });

  group('NotificationManager', () {
    late AtServerTelemetry telemetry;
    late NotificationManager notificationManager;

    AtNotification notificationForBob({DateTime? expiresAt}) {
      return (AtNotificationBuilder()
            ..id = 'n-1'
            ..type = NotificationType.sent
            ..fromAtSign = alice
            ..toAtSign = bob
            ..notification = '@bob:phone.wavi@alice'
            ..expiresAt = expiresAt)
          .build();
    }

    Future<void> send(AtNotification notification) {
      return notificationManager
          .getPerAtSignNotifSender(bob)
          .send(notification);
    }

    void bobAccepts() {
      final OutboundClient client = MockOutboundClient();
      when(() =>
              notificationManager.notifyConnectionsPool.getOutboundClient(bob))
          .thenAnswer((_) async => client);
      when(() => client.notify(any())).thenAnswer((_) async => 'data:success');
    }

    setUp(() {
      telemetry = AtServerTelemetry(heartbeatInterval: null)
        ..enable(
          exporter: _RecordingExporter(records),
          serverId: '$alice',
          bootId: 'boot-1',
        );
      records.clear();
      notificationManager = NotificationManager(
        alice,
        MockAtNotificationKeystore(),
        MockNotifyConnectionsPool(),
        telemetry: telemetry,
      );
      when(() => notificationManager.notifStore.put(any(), any(),
          skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async => null);
    });

    tearDown(() async {
      await telemetry.shutdown();
    });

    test('says a notification was delivered once its recipient accepts it',
        () async {
      bobAccepts();

      await send(notificationForBob());

      expect(names(), <String>[atServerNotificationDeliveredEventName]);
      expect(notificationEvents().single.attributes, <String, Object?>{
        notificationToAttribute: '@bob',
        AtTelemetryAttributes.notificationIds: <String>['n-1'],
      });
    });

    test('says a notification expired before it could be delivered', () async {
      await send(notificationForBob(
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1))));

      expect(names(), <String>[atServerNotificationExpiredEventName]);
      expect(notificationEvents().single.attributes, <String, Object?>{
        notificationToAttribute: '@bob',
        AtTelemetryAttributes.notificationIds: <String>['n-1'],
      });
    });

    test('says it gave up on a notification for an atSign that does not exist',
        () async {
      final MockSecondaryAddressFinder addressFinder =
          MockSecondaryAddressFinder();
      when(() =>
              notificationManager.notifyConnectionsPool.secondaryAddressFinder)
          .thenReturn(addressFinder);
      when(() =>
              notificationManager.notifyConnectionsPool.getOutboundClient(bob))
          .thenAnswer((_) async => throw Exception('no route to @bob'));
      when(() => addressFinder.findSecondary(bob)).thenAnswer(
          (_) async => throw SecondaryNotFoundException('@bob not found'));

      await send(notificationForBob());

      expect(names(), <String>[atServerNotificationErrorEventName]);
      expect(notificationEvents().single.attributes, <String, Object?>{
        notificationToAttribute: '@bob',
        AtTelemetryAttributes.notificationIds: <String>['n-1'],
      });
    });

    test('sends nothing while telemetry is off', () async {
      await telemetry.shutdown();
      records.clear();
      bobAccepts();

      await send(notificationForBob());

      expect(records, isEmpty);
    });
  });

  group('another atServer delivering a notification', () {
    late AtServerTelemetry telemetry;
    late NotifyVerbHandler notify;

    Future<void> deliver(String id) async {
      inboundConnection.metadata
        ..isAuthenticated = false
        ..isPolAuthenticated = true
        ..fromAtSign = bob;
      await notify.processInternal(
          'notify:id:$id:update:messageType:key:notifier:system'
          ':ttln:60000:@alice:phone.wavi@bob:v',
          inboundConnection);
    }

    setUp(() async {
      await verbTestsSetUp();
      telemetry = AtSecondaryServerImpl.getInstance().telemetry
        ..enable(
          exporter: _RecordingExporter(records),
          serverId: '$alice',
          bootId: 'boot-2',
        );
      records.clear();
      notify = NotifyVerbHandler(keyValueStore, notificationManager);
    });

    tearDown(() async {
      await telemetry.shutdown();
      await verbTestsTearDown();
    });

    test('says the notification was received, once', () async {
      await deliver('n-2');
      await deliver('n-2');

      expect(names(), <String>[atServerNotificationReceivedEventName]);
      expect(notificationEvents().single.attributes, <String, Object?>{
        notificationFromAttribute: '@bob',
        AtTelemetryAttributes.notificationIds: <String>['n-2'],
      });
    });

    test('says a monitor was pushed the notification', () async {
      final DummyInboundConnection monitorConnection = DummyInboundConnection();
      monitorConnection.metadata
        ..isAuthenticated = true
        ..authType = AuthType.cram;
      await MonitorVerbHandler(keyValueStore, notificationManager).processVerb(
          Response(), HashMap<String, String?>(), monitorConnection);

      await deliver('n-3');
      await Future<void>.delayed(Duration.zero);

      expect(names(), <String>[
        atServerNotificationReceivedEventName,
        atServerNotificationPushedEventName,
      ]);
      expect(notificationEvents().last.attributes, <String, Object?>{
        notificationFromAttribute: '@bob',
        AtTelemetryAttributes.notificationIds: <String>['n-3'],
      });
      expect(monitorConnection.lastWrittenData, contains('n-3'));
    });
  });

  group('notificationPushed', () {
    test('names the enrollment of the monitor it was pushed to', () async {
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null)
            ..enable(
              exporter: _RecordingExporter(records),
              serverId: '$alice',
              bootId: 'boot-3',
            );
      addTearDown(telemetry.shutdown);
      records.clear();

      telemetry.notificationPushed(
        (AtNotificationBuilder()
              ..id = 'n-4'
              ..fromAtSign = bob)
            .build(),
        enrollmentId: 'enrollment-1',
      );

      expect(notificationEvents().single.attributes, <String, Object?>{
        notificationFromAttribute: '@bob',
        AtTelemetryAttributes.enrollmentId: 'enrollment-1',
        AtTelemetryAttributes.notificationIds: <String>['n-4'],
      });
    });
  });
}

final class _RecordingExporter implements AtTelemetryLogRecordExporter {
  final List<AtTelemetryLogRecord> _records;

  _RecordingExporter(this._records);

  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) async {
    _records.add(logRecord);
    return true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}
