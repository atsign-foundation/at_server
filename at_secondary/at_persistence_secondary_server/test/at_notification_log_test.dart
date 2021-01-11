import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_log.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_entry.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';
import 'dart:io';

void main() async {
  var storagePath = Directory.current.path + '/test/notifications';
  var maxNotifications = 5;
  setUp(() async => await setUpFunc(storagePath, maxNotifications));

  group('A group of notification log test', () {
    test('test insert received notification', () async {
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      var atNotification = AtNotification(
          '123',
          '@colin',
          DateTime.now().toUtc(),
          '@colin',
          'self_received_notification',
          NotificationType.received,
          OperationType.update);
      var notificationEntry1 = NotificationEntry([], [atNotification]);
      await notificationKeyStore.put('@colin', notificationEntry1);
      var notificationEntry = await notificationKeyStore.get('@colin');
      expect(notificationEntry.runtimeType, NotificationEntry);
      expect(notificationEntry.receivedNotifications.length, 1);
      expect(notificationEntry.sentNotifications.length, 0);
    });

    test('test insert sent notification', () async {
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      var atNotification = AtNotification(
          '123',
          '@colin',
          DateTime.now().toUtc(),
          '@bob',
          'sent_notification',
          NotificationType.sent,
          OperationType.update);
      var notificationEntry1 = NotificationEntry([atNotification], []);
      await notificationKeyStore.put('@colin', notificationEntry1);
      var notificationEntry = await notificationKeyStore.get('@colin');
      expect(notificationEntry.runtimeType, NotificationEntry);
      expect(notificationEntry.receivedNotifications.isEmpty, true);
      expect(notificationEntry.sentNotifications.length, 1);
    });
    test('test multiple insert', () async {
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      var atNotification = AtNotification(
          '123',
          '@colin',
          DateTime.now().toUtc(),
          '@bob',
          'sent_notification1',
          NotificationType.sent,
          OperationType.update);
      var notificationEntry1 = NotificationEntry([atNotification], []);
      await notificationKeyStore.put('@colin', notificationEntry1);
      var atNotification1 = AtNotification(
          '123',
          '@colin',
          DateTime.now().toUtc(),
          '@bob',
          'sent_notification2',
          NotificationType.sent,
          OperationType.update,
          null);
      var notificationEntry2 = NotificationEntry([atNotification1], []);
      await notificationKeyStore.put('@colin', notificationEntry2);
      var atNotification2 = AtNotification(
          '123',
          '@colin',
          DateTime.now().toUtc(),
          '@bob',
          'sent_notification3',
          NotificationType.sent,
          OperationType.update,
          null);
      var notificationEntry3 = NotificationEntry([atNotification2], []);
      await notificationKeyStore.put('@colin', notificationEntry3);
      var notificationEntry = await notificationKeyStore.get('@colin');
      expect(notificationEntry.runtimeType, NotificationEntry);
      expect(notificationEntry.receivedNotifications.isEmpty, true);
      expect(notificationEntry.sentNotifications.isEmpty, false);
      expect(notificationEntry.sentNotifications.length, 3);
    });

    test('test get NotificationEntry ', () async {
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      var atNotification = AtNotification(
          '123',
          '@colin',
          DateTime.now().toUtc(),
          '@bob',
          'sent_notification1',
          NotificationType.sent,
          OperationType.update);
      var notificationEntry1 = NotificationEntry([atNotification], []);
      await notificationKeyStore.put('@colin', notificationEntry1);
      var notificationEntry = await notificationKeyStore.get('@colin');
      expect(notificationEntry.sentNotifications.isEmpty, false);
      var at_notification = notificationEntry.sentNotifications.first;
      expect(at_notification.fromAtSign, '@colin');
      expect(at_notification.toAtSign, '@bob');
      expect(at_notification.notification, 'sent_notification1');
      expect(at_notification.notificationDateTime.isUtc, true);
    });

    test('test insert entry - box not available', () async {
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      var atNotification = AtNotification(
          '123',
          '@alice',
          DateTime.now().toUtc(),
          '@bob',
          'test',
          NotificationType.sent,
          OperationType.update,
          null);
      var notificationEntry1 = NotificationEntry([atNotification], []);
      await AtNotificationLog.getInstance().box.close();
      expect(
          () async =>
              await notificationKeyStore.put('@bob', notificationEntry1),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    test('test register callback', () async {
      var notificationLogInstance = AtNotificationLog.getInstance();
      notificationLogInstance.registerNotificationCallback(
          NotificationType.received, processReceiveNotification);
      notificationLogInstance = null;
    });
  });

  tearDown(() async => tearDownFunc(storagePath));
}

void setUpFunc(storagePath, maxNotifications) async {
  await AtNotificationLog.getInstance()
      .init('test_notify', storagePath, maxNotifications);
}

void processReceiveNotification(AtNotification atNotification) {
  print(atNotification);
}

Future<void> tearDownFunc(String storagePath) async {
  await Hive.deleteBoxFromDisk('test_notify');
  var isExists = await Directory('test/notifications').exists();

  if(isExists){
    await Directory(storagePath).deleteSync(recursive: true);
  }

}
