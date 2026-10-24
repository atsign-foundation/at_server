import 'dart:async';
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
import 'package:logging/logging.dart' show Level, LogRecord;
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

    Future<DummyInboundConnection> monitor({
      AuthType authType = AuthType.cram,
      String? enrollmentId,
      String? regex,
    }) async {
      final DummyInboundConnection connection = DummyInboundConnection();
      connection.metadata
        ..isAuthenticated = true
        ..authType = authType
        ..enrollmentId = enrollmentId
        ..clientId = 'client-${enrollmentId ?? 'cram'}'
        ..appName = 'chat'
        ..appVersion = '1.2.3'
        ..platform = 'android';
      await MonitorVerbHandler(keyValueStore, notificationManager).processVerb(
          Response(),
          HashMap<String, String?>.of(<String, String?>{
            if (regex != null) AtConstants.regex: regex,
          }),
          connection);
      return connection;
    }

    test('says the notification was received, once', () async {
      await deliver('n-2');
      await deliver('n-2');
      await pumpEventQueue();

      expect(names(), <String>[atServerNotificationReceivedEventName]);
      expect(notificationEvents().single.attributes, <String, Object?>{
        notificationFromAttribute: '@bob',
        notificationPushCountAttribute: 0,
        AtTelemetryAttributes.notificationIds: <String>['n-2'],
      });
    });

    test('lists the monitor connections it was pushed to', () async {
      final String phone = await createAndPersistAnEnrollment(
          'chat', 'phone', <String, String>{'wavi': 'rw'});
      final String other = await createAndPersistAnEnrollment(
          'chat', 'tablet', <String, String>{'other': 'rw'});
      final DummyInboundConnection pushed =
          await monitor(authType: AuthType.apkam, enrollmentId: phone);
      final DummyInboundConnection unauthorized =
          await monitor(authType: AuthType.apkam, enrollmentId: other);
      final DummyInboundConnection unmatched = await monitor(regex: 'nomatch');

      await deliver('n-3');
      await pumpEventQueue();

      expect(names(), <String>[atServerNotificationReceivedEventName]);
      expect(notificationEvents().single.attributes, <String, Object?>{
        notificationFromAttribute: '@bob',
        notificationPushCountAttribute: 1,
        notificationPushedToAttribute: <Map<String, Object?>>[
          <String, Object?>{
            connectionIdAttribute: pushed.metadata.connectionId,
            AtTelemetryAttributes.enrollmentId: phone,
            connectionAuthTypeAttribute: 'apkam',
          },
        ],
        AtTelemetryAttributes.notificationIds: <String>['n-3'],
      });
      expect(pushed.lastWrittenData, contains('n-3'));
      expect(unauthorized.lastWrittenData ?? '', isNot(contains('n-3')));
      expect(unmatched.lastWrittenData ?? '', isNot(contains('n-3')));
    });
  });

  group('undelivered events', () {
    late AtServerTelemetry telemetry;
    late List<String> warnings;
    final AtNotification notification = (AtNotificationBuilder()
          ..id = 'n-5'
          ..toAtSign = bob)
        .build();

    setUp(() async {
      telemetry = AtServerTelemetry(heartbeatInterval: null);
      telemetry.logger.level = 'warning';
      warnings = <String>[];
      final StreamSubscription<LogRecord> subscription = telemetry
          .logger.logger.onRecord
          .where((LogRecord record) => record.level == Level.WARNING)
          .listen((LogRecord record) => warnings.add(record.message));
      addTearDown(subscription.cancel);
      telemetry.enable(
        exporter: _RecordingExporter(records, delivers: false),
        serverId: '$alice',
        bootId: 'boot-4',
      );
      await pumpEventQueue();
      records.clear();
      warnings.clear();
    });

    tearDown(() async {
      await telemetry.shutdown();
    });

    test('make one warning for each failure, not one for each event', () async {
      for (int i = 0; i < 500; i++) {
        telemetry.notificationDelivered(notification);
      }
      await pumpEventQueue();
      telemetry.notificationExpired(notification);
      await pumpEventQueue();

      expect(records, hasLength(501));
      expect(warnings, <String>[
        'Telemetry events not delivered: 500 '
            '($atServerNotificationDeliveredEventName x500)',
        'Telemetry events not delivered: 1 '
            '($atServerNotificationExpiredEventName x1)',
      ]);
    });

    test('are reported before shutdown returns', () async {
      for (int i = 0; i < 3; i++) {
        telemetry.notificationDelivered(notification);
      }

      await telemetry.shutdown();
      final List<String> atShutdown = List<String>.of(warnings);
      await pumpEventQueue();

      expect(atShutdown, <String>[
        'Telemetry events not delivered: 4 '
            '($atServerNotificationDeliveredEventName x3, '
            '$atServerStoppedEventName x1)',
      ]);
      expect(warnings, atShutdown);
    });
  });
}

final class _RecordingExporter implements AtTelemetryLogRecordExporter {
  final List<AtTelemetryLogRecord> _records;
  final bool _delivers;

  _RecordingExporter(this._records, {bool delivers = true})
      : _delivers = delivers;

  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) async {
    _records.add(logRecord);
    return _delivers;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}
