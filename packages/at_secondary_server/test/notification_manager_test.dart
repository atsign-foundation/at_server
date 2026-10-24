import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart'
    show OutboundClient;
import 'package:at_secondary/src/notification/monitor_sink.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_server_spec/at_server_spec.dart' show InboundConnection;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() async {
  // verbTestsSetUpLogging();

  // The notification keystore is now typed KeyValueStore<String,
  // AtNotification>, so mocktail's `any()` on a `put` value argument
  // needs a registered fallback for the non-primitive AtNotification.
  setUpAll(() {
    registerFallbackValue(AtNotificationBuilder().build());
  });

  NotificationManager makeMgr() {
    var nm = NotificationManager(
      alice,
      MockAtNotificationKeystore(),
      MockNotifyConnectionsPool(),
    );
    when(() => nm.notifStore.put(any(), any(),
        skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async {
      return;
    });
    return nm;
  }

  group('Test delivery to correct streams', () {
    test('Test delivery of a self notification to monitors with toAtSign',
        () async {
      var nm = makeMgr();
      var monitor = RecordingMonitorSink();
      nm.addMonitor(monitor);
      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.self
            ..toAtSign = alice
            ..fromAtSign = alice
            ..notification = 'verify_delivery_to_self$alice')
          .build();
      nm.enqueue(sent);
      expect(monitor.pushed, [sent]);
    });
    test('Test delivery of a self notification to monitors without toAtSign',
        () async {
      var nm = makeMgr();
      var monitor = RecordingMonitorSink();
      nm.addMonitor(monitor);
      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.self
            ..fromAtSign = alice
            ..notification = 'verify_delivery_to_self_without_to$alice')
          .build();
      nm.enqueue(sent);
      expect(monitor.pushed, [sent]);
    });
    test('Test delivery to self stream with mismatched toAtSign', () async {
      var nm = makeMgr();
      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.self
            ..toAtSign = '@bob'
            ..fromAtSign = alice
            ..notification = 'verify_delivery_to_self_with_mismatched_to$alice')
          .build();
      expect(() => nm.enqueue(sent), throwsA(isA<StateError>()));
    });
    test('Test delivery to sent stream', () async {
      var nm = makeMgr();
      OutboundClient oc = MockOutboundClient();
      when(() =>
              nm.notifyConnectionsPool.getOutboundClient(any(), connect: true))
          .thenAnswer((_) async => oc);
      when(() => oc.notify(any(), handshake: true))
          .thenAnswer((_) async => 'data:success');

      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.sent
            ..toAtSign = '@bob'
            ..fromAtSign = alice
            ..notification = 'verify_delivery_to_sent$alice')
          .build();
      var rcvdFuture = nm.sent.stream.first;
      nm.enqueue(sent);
      var rcvd = await rcvdFuture;
      expect(rcvd, sent);
    });
    test('Test delivery to sent stream with mismatched toAtSign', () async {
      var nm = makeMgr();
      OutboundClient oc = MockOutboundClient();
      when(() =>
              nm.notifyConnectionsPool.getOutboundClient(any(), connect: true))
          .thenAnswer((_) async => oc);
      when(() => oc.notify(any(), handshake: true))
          .thenAnswer((_) async => 'data:success');

      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.sent
            ..toAtSign = alice
            ..fromAtSign = alice
            ..notification = 'verify_sent_with_mismatched_to_atsign$alice')
          .build();
      expect(() => nm.enqueue(sent), throwsA(isA<StateError>()));
    });

    test('Test delivery to sent stream with mismatched fromAtSign', () async {
      var nm = makeMgr();
      OutboundClient oc = MockOutboundClient();
      when(() =>
              nm.notifyConnectionsPool.getOutboundClient(any(), connect: true))
          .thenAnswer((_) async => oc);
      when(() => oc.notify(any(), handshake: true))
          .thenAnswer((_) async => 'data:success');

      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.sent
            ..toAtSign = '@chuck'
            ..fromAtSign = '@bob'
            ..notification =
                '@chuck:verify_sent_with_mismatched_from_atsign@bob')
          .build();
      expect(() => nm.enqueue(sent), throwsA(isA<StateError>()));
    });
    test('Test delivery of a received notification to monitors', () async {
      var nm = makeMgr();
      var monitor = RecordingMonitorSink();
      nm.addMonitor(monitor);
      var received = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.received
            ..toAtSign = alice
            ..fromAtSign = '@bob'
            ..notification = '$alice:verify_delivery_to_monitors@bob')
          .build();
      nm.enqueue(received);
      expect(monitor.pushed, [received]);
    });

    test(
        'Given a feed that throws, when a received notification is queued, then the feeds after it still get it and one severe line names it and its connection',
        () async {
      final NotificationManager nm = makeMgr();
      final RecordingMonitorSink before = RecordingMonitorSink();
      final RecordingMonitorSink after = RecordingMonitorSink();
      nm.addMonitor(before);
      nm.addMonitor(_ThrowingSink(
          DummyInboundConnection()..metadata.sessionID = 'broken-session'));
      nm.addMonitor(after);
      final Level prior = nm.logger.logger.level;
      nm.logger.level = 'warning';
      final List<String> severe = <String>[];
      final StreamSubscription<LogRecord> logs = nm.logger.logger.onRecord
          .where((LogRecord r) => r.level == Level.SEVERE)
          .listen((LogRecord r) => severe.add(r.message));
      addTearDown(() async {
        await logs.cancel();
        nm.logger.logger.level = prior;
      });
      final AtNotification received = (AtNotificationBuilder()
            ..id = 'n1'
            ..type = NotificationType.received
            ..toAtSign = alice
            ..fromAtSign = '@bob'
            ..notification = '$alice:phone.wavi@bob')
          .build();

      nm.enqueue(received);

      expect(before.pushed, [received]);
      expect(after.pushed, [received]);
      expect(
          severe.single,
          allOf(contains('feed broke'), contains('notification n1'),
              contains('$alice:phone.wavi@bob'), contains('broken-session')));
    });
  });

  group('Test states and guards', () {
    test('Verify initial state', () {
      var nm = makeMgr();
      expect(nm.closed, false);
      expect(nm.senders, isEmpty);
      expect(nm.monitorCount, 0);
      expect(nm.sent.isClosed, false);
      expect(nm.sent.isPaused, false);
    });

    test(
        'Given a newer feed for a connection, when removing only the older one, then the newer one stays',
        () {
      var nm = makeMgr();
      var connection = DummyInboundConnection();
      var older = RecordingMonitorSink(connection);
      var newer = RecordingMonitorSink(connection);
      nm.addMonitor(older);
      nm.addMonitor(newer);

      nm.removeMonitor(connection, only: older);

      expect(nm.monitorCount, 1);
      expect(newer.closed, false);
    });

    test('Verify notify closed guard', () async {
      var nm = makeMgr();
      await nm.close();
      await expectLater(nm.notify(AtNotificationBuilder().build()),
          throwsA(predicate((dynamic e) => e is StateError)));
    });

    test('send() abandons its retry loop once the manager is closed',
        () async {
      final savedInitialDelay = PerAtSignNotifSender.initialDelay;
      PerAtSignNotifSender.initialDelay = Duration(milliseconds: 5);
      addTearDown(
          () => PerAtSignNotifSender.initialDelay = savedInitialDelay);

      var nm = makeMgr();
      var addressFinder = MockSecondaryAddressFinder();
      when(() => addressFinder.findSecondary(bob)).thenAnswer(
          (_) async => at_lookup.SecondaryAddress('bob.example.com', 1234));
      when(() => nm.notifyConnectionsPool.secondaryAddressFinder)
          .thenReturn(addressFinder);

      // Delivery never succeeds, so `send()` sits in its retry loop.
      var attempts = 0;
      when(() => nm.notifyConnectionsPool.getOutboundClient(bob))
          .thenAnswer((_) async {
        attempts++;
        throw Exception('mock: delivery fails');
      });

      await nm.notify((AtNotificationBuilder()
            ..id = 'retry-loop-stops-on-close'
            ..type = NotificationType.sent
            ..fromAtSign = alice
            ..toAtSign = '@bob'
            ..notification = '@bob:verify_retry_stops$alice')
          .build());

      await Future.delayed(Duration(milliseconds: 100));
      expect(attempts, greaterThan(1),
          reason: 'precondition: the retry loop should be running');

      await nm.close();
      // Let whichever iteration was already in flight finish.
      await Future.delayed(Duration(milliseconds: 100));
      var attemptsAfterClose = attempts;

      await Future.delayed(Duration(milliseconds: 200));
      expect(attempts, attemptsAfterClose,
          reason: 'send() kept retrying after the manager was closed');
    });

    test(
        'Given a notification the recipient\'s atServer refuses, when it is retried until it expires, then later notifications to that atSign wait behind it and it ends expired',
        () async {
      final Duration savedInitialDelay = PerAtSignNotifSender.initialDelay;
      final Duration savedMaxDelay = PerAtSignNotifSender.maxDelay;
      PerAtSignNotifSender.initialDelay = const Duration(milliseconds: 5);
      PerAtSignNotifSender.maxDelay = const Duration(milliseconds: 20);
      addTearDown(() {
        PerAtSignNotifSender.initialDelay = savedInitialDelay;
        PerAtSignNotifSender.maxDelay = savedMaxDelay;
      });
      final NotificationManager nm = makeMgr();
      addTearDown(nm.close);
      final MockSecondaryAddressFinder addressFinder =
          MockSecondaryAddressFinder();
      when(() => addressFinder.findSecondary(bob)).thenAnswer(
          (_) async => at_lookup.SecondaryAddress('bob.example.com', 1234));
      when(() => nm.notifyConnectionsPool.secondaryAddressFinder)
          .thenReturn(addressFinder);
      final MockOutboundClient client = MockOutboundClient();
      when(() => nm.notifyConnectionsPool.getOutboundClient(bob))
          .thenAnswer((_) async => client);
      when(() => client.usePeerFeature(any())).thenAnswer((_) async => false);
      final List<(String, DateTime)> attempts = <(String, DateTime)>[];
      when(() => client.notify(any())).thenAnswer((Invocation i) async {
        final String body = i.positionalArguments[0] as String;
        final String key = body.contains('refused') ? 'refused' : 'later';
        attempts.add((key, DateTime.now()));
        return key == 'refused'
            ? 'error:AT0003-Exception: notification id must have at most 36'
                ' characters'
            : 'data:success';
      });
      AtNotification sent(String key, {int? ttl}) => (AtNotificationBuilder()
            ..id = key
            ..type = NotificationType.sent
            ..fromAtSign = alice
            ..toAtSign = '@bob'
            ..notification = '@bob:$key$alice'
            ..ttl = ttl)
          .build();
      final AtNotification refused = sent('refused', ttl: 300);

      await nm.notify(refused);
      await nm.notify(sent('later'));
      for (int i = 0;
          i < 300 && !attempts.any(((String, DateTime) a) => a.$1 == 'later');
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final List<DateTime> refusals = [
        for (final (String key, DateTime at) in attempts)
          if (key == 'refused') at
      ];
      final DateTime laterAt =
          attempts.firstWhere(((String, DateTime) a) => a.$1 == 'later').$2;
      expect(refusals.length, greaterThan(1),
          reason: 'a refused notification is retried');
      expect(laterAt.isBefore(refused.expiresAt!), isFalse,
          reason: 'the later one is not sent until the refused one expires');
      expect(laterAt.isBefore(refusals.last), isFalse);
      expect(refused.notificationStatus, NotificationStatus.expired);
    });

    test('Verify close', () async {
      var nm = makeMgr();
      var monitor = RecordingMonitorSink();
      nm.addMonitor(monitor);
      await nm.notify((AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.sent
            ..fromAtSign = alice
            ..toAtSign = '@bob'
            ..notification = '@bob:verify_close$alice')
          .build());
      await nm.close();
      expect(nm.closed, true);
      expect(monitor.closed, true);
      expect(nm.monitorCount, 0);
      expect(() => nm.addMonitor(RecordingMonitorSink()),
          throwsA(isA<StateError>()));
      expect(nm.sent.isClosed, true);
    });
  });

  group('Tests of prepareNotifyCommandBody', () {
    NotificationManager notificationManager = NotificationManager(
      alice,
      MockAtNotificationKeystore(),
      MockNotifyConnectionsPool(),
    );

    test('Test to verify prepare notification command', () async {
      var atNotification = (AtNotificationBuilder()
            ..id = '1234'
            ..notification = '@bob:phone$alice')
          .build();

      await Future.delayed(Duration(milliseconds: 10));
      var notifyCommand =
          notificationManager.prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(
          notifyCommand,
          matches(RegExp('id:1234:messageType:key:notifier:system'
              ':ttln:\\d{6}:@bob:phone$alice')));
    });

    test('Test to verify prepare notification without passing any fields',
        () async {
      var atNotification = (AtNotificationBuilder()..id = '1122').build();
      var notifyCommand =
          notificationManager.prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(
          notifyCommand,
          matches(RegExp('id:1122:messageType:key:notifier:system'
              ':ttln:\\d{6}:null')));
    });

    test('Test to verify prepare notification command for delete notification',
        () {
      var atNotification = (AtNotificationBuilder()
            ..id = '1234'
            ..notification = '@bob:phone$alice'
            ..opType = OperationType.delete)
          .build();
      var notifyCommand =
          notificationManager.prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(
          notifyCommand,
          matches(RegExp('id:1234:delete:messageType:key:notifier:system'
              ':ttln:\\d{6}:@bob:phone$alice')));
    });

    testNotificationMetaData({required bool immutable}) {
      var ttln = 55555;
      var fromAtsign = alice;
      var atNotification = (AtNotificationBuilder()
            ..fromAtSign = fromAtsign
            ..toAtSign = '@bob'
            ..id = '1234'
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..atValue = 'Hi Bob, Alice here'
            ..notification = '@bob:test.test$fromAtsign'
            ..notificationDateTime = DateTime.now().toUtcMillisecondsPrecision()
            ..ttl = ttln
            ..atMetaData = AtMetaData.fromCommonsMetadata(
              Metadata()
                ..ttr = 1
                ..ccd = true
                ..pubKeyCS = '123'
                ..sharedKeyEnc = 'abc'
                ..encKeyName = 'ekn'
                ..encAlgo = 'ea'
                ..ivNonce = 'ivn'
                ..skeEncKeyName = 'ske_ekn'
                ..skeEncAlgo = 'ske_ea'
                ..pubKeyHash = PublicKeyHash('someHash', 'someAlgo')
                ..immutable = immutable,
              fromAtsign,
            ))
          .build();

      var notifyCommand =
          notificationManager.prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(
          notifyCommand,
          matches(RegExp('id:1234:update:messageType:key:notifier:system'
              ':ttln:\\d{5}'
              ':ttr:1:ccd:true'
              // fromCommonsMetadata's builder pass stamps
              // createdAt/updatedAt, and the emitter transmits whatever
              // timestamps the notification's metadata carries.
              ':cAt:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}Z'
              ':uAt:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}Z'
              ':isEncrypted:false'
              ':sharedKeyEnc:abc:pubKeyCS:123'
              ':pubKeyHash:someHash:hashingAlgo:someAlgo'
              ':encKeyName:ekn:encAlgo:ea:ivNonce:ivn'
              ':skeEncKeyName:ske_ekn:skeEncAlgo:ske_ea'
              '${immutable ? ':immutable:true' : ''}'
              ':@bob:test.test$alice'
              ':Hi Bob, Alice here')));
    }

    test(
        'Test to verify prepare an update notification command with a value and all the metadata',
        () {
      testNotificationMetaData(immutable: false);
      testNotificationMetaData(immutable: true);
    });
  });
}

/// A monitor feed whose push throws.
class _ThrowingSink implements MonitorSink {
  _ThrowingSink(this.connection);

  @override
  final InboundConnection connection;

  @override
  void push(AtNotification n, {LivePushReport? report}) =>
      throw StateError('feed broke');

  @override
  Future<void> get idle => Future<void>.value();

  @override
  int get queued => 0;

  @override
  void close() {}
}
