import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart'
    show OutboundClient;
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
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
    test('Test delivery to self stream with toAtSign', () async {
      var nm = makeMgr();
      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.self
            ..toAtSign = alice
            ..fromAtSign = alice
            ..notification = 'verify_delivery_to_self$alice')
          .build();
      var rcvdFuture = nm.self.stream.first;
      nm.enqueue(sent);
      var rcvd = await rcvdFuture;
      expect(rcvd, sent);
    });
    test('Test delivery to self stream without toAtSign', () async {
      var nm = makeMgr();
      var sent = (AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.self
            ..fromAtSign = alice
            ..notification = 'verify_delivery_to_self_without_to$alice')
          .build();
      var rcvdFuture = nm.self.stream.first;
      nm.enqueue(sent);
      var rcvd = await rcvdFuture;
      expect(rcvd, sent);
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
    test('Test delivery to received stream', () async {});
  });

  group('Test states and guards', () {
    test('Verify initial state', () {
      var nm = makeMgr();
      expect(nm.closed, false);
      expect(nm.senders, isEmpty);
      expect(nm.self.isClosed, false);
      expect(nm.self.isPaused, false);
      expect(nm.received.isClosed, false);
      expect(nm.received.isPaused, false);
      expect(nm.sent.isClosed, false);
      expect(nm.sent.isPaused, false);
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

    test('Verify close', () async {
      var nm = makeMgr();
      await nm.notify((AtNotificationBuilder()
            ..id = 'abcde'
            ..type = NotificationType.sent
            ..fromAtSign = alice
            ..toAtSign = '@bob'
            ..notification = '@bob:verify_close$alice')
          .build());
      await nm.close();
      expect(nm.closed, true);
      expect(nm.self.isClosed, true);
      expect(nm.received.isClosed, true);
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

    test('Test to verify prepare notification command for message type text',
        () {
      var atNotification = (AtNotificationBuilder()
            ..id = '1234'
            ..notification = '@bob:phone$alice'
            ..notifier = 'wavi'
            ..messageType = MessageType.text)
          .build();
      var notifyCommand =
          notificationManager.prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(
          notifyCommand,
          matches(RegExp('id:1234:messageType:text:notifier:wavi'
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
