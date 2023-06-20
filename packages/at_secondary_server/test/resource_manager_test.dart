import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/notification/resource_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockOutboundClient extends Mock implements OutboundClient {}

void main() async {
  // mock object for outbound client
  OutboundClient mockOutboundClient = MockOutboundClient();
  ResourceManager rm = ResourceManager.getInstance();
  var storageDir = '${Directory.current.path}/test/hive';

  //  forcing the notification sending to fail with an exception
  setUp(() {
    reset(mockOutboundClient);
    when(() => mockOutboundClient.notify(any())).thenAnswer((_) async {
      throw Exception('Failed to Notify');
    });
  });

  /// Purpose of the test is to do the following
  /// 1) Passing an notification iterator having valid & invalid notifications.
  /// 2) Verifying that all of the queued notifications are still enqueued when one of the notification is invalid.
  /// 3) dequeue() should return the same 3 notifications as the one's we passed
  group('A group of notify verb test', () {
    setUp(() async => await setUpFunc(storageDir));
    test('Test send notifications', () async {
      var atNotification1 = (AtNotificationBuilder()
            ..id = '121'
            ..atValue = 'bob@gmail.com'
            ..notification = 'email'
            ..fromAtSign = '@bob'
            ..toAtSign = '@alice'
            ..strategy = 'all'
            ..opType = OperationType.update
            ..ttl = -1
            ..retryCount = 1)
          .build();
      var atNotification2 = (AtNotificationBuilder()
            ..id = '122'
            ..atValue = '90192019021'
            ..fromAtSign = '@bob'
            ..toAtSign = '@alice'
            ..strategy = 'all'
            ..opType = OperationType.update
            ..notification = 'phone'
            ..retryCount = 1)
          .build();
      var atNotification3 = (AtNotificationBuilder()
            ..id = '123'
            ..fromAtSign = '@bob'
            ..toAtSign = '@alice'
            ..atValue = 'USA'
            ..strategy = 'all'
            ..opType = OperationType.update
            ..notification = 'location'
            ..retryCount = 1)
          .build();

      var atsign = '@alice';
      // Iterator containing all the notifications
      Iterator notificationIterator =
          [atNotification1, atNotification2, atNotification3].iterator;
      await rm.sendNotifications(
          atsign, mockOutboundClient, notificationIterator);
      var atNotificationList = [];
      var itr = QueueManager.getInstance().dequeue(atsign);
      while (itr.moveNext()) {
        atNotificationList.add(itr.current);
      }
      // Expecting that the atNotificationList[0] returned from the dequeue() is same as the notification we passed i.e., atNotificationid1.id
      expect(atNotificationList[0].id, '121');
      // Expecting that the atNotificationList[1] returned from the dequeue() is same as the notification we passed i.e., atNotificationid2.id
      expect(atNotificationList[1].id, '122');
      // Expecting that the atNotificationList[2] returned from the dequeue() is same as the notification we passed i.e., atNotificationid3.id
      expect(atNotificationList[2].id, '123');
    }, timeout: Timeout(Duration(seconds: 10)));
  });

  group('A group of tests to resource_manager', () {
    test('Test to verify prepare notification command', () {
      var atNotification = (AtNotificationBuilder()
            ..id = '1234'
            ..notification = '@bob:phone@alice')
          .build();

      var notifyCommand = ResourceManager.getInstance()
          .prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(notifyCommand,
          'id:1234:messageType:key:notifier:system:ttln:900000:@bob:phone@alice');
    });

    test('Test to verify prepare notification without passing any fields', () {
      var atNotification = (AtNotificationBuilder()..id = '1122').build();
      var notifyCommand = ResourceManager.getInstance()
          .prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(notifyCommand,
          'id:1122:messageType:key:notifier:system:ttln:900000:null');
    });

    test('Test to verify prepare notification command for delete notification',
        () {
      var atNotification = (AtNotificationBuilder()
            ..id = '1234'
            ..notification = '@bob:phone@alice'
            ..opType = OperationType.delete)
          .build();
      var notifyCommand = ResourceManager.getInstance()
          .prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(notifyCommand,
          'id:1234:delete:messageType:key:notifier:system:ttln:900000:@bob:phone@alice');
    });

    test('Test to verify prepare notification command for message type text',
        () {
      var atNotification = (AtNotificationBuilder()
            ..id = '1234'
            ..notification = '@bob:phone@alice'
            ..notifier = 'wavi'
            ..messageType = MessageType.text)
          .build();
      var notifyCommand = ResourceManager.getInstance()
          .prepareNotifyCommandBody(atNotification);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(notifyCommand,
          'id:1234:messageType:text:notifier:wavi:ttln:900000:@bob:phone@alice');
    });

    test(
        'Test to verify prepare an update notification command with a value and all the metadata',
        () {
      var ttln = 24 * 60 * 60 * 1000;
      var atNotification = (AtNotificationBuilder()
            ..fromAtSign = '@alice'
            ..toAtSign = '@bob'
            ..id = '1234'
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..atValue = 'Hi Bob, Alice here'
            ..notification = '@bob:test.test@alice'
            ..notificationDateTime = DateTime.now().toUtcMillisecondsPrecision()
            ..ttl = ttln
            ..atMetaData = AtMetaData.fromCommonsMetadata(Metadata()
              ..ttr = 1
              ..ccd = true
              ..pubKeyCS = '123'
              ..sharedKeyEnc = 'abc'
              ..encKeyName = 'ekn'
              ..encAlgo = 'ea'
              ..ivNonce = 'ivn'
              ..skeEncKeyName = 'ske_ekn'
              ..skeEncAlgo = 'ske_ea'))
          .build();

      var notifyCommand = ResourceManager.getInstance()
          .prepareNotifyCommandBody(atNotification);

      print(notifyCommand);

      /// expecting that prepareNotifyCommandBody returns the notify command same as atNotification
      expect(
          notifyCommand,
          'id:1234:update:messageType:key:notifier:system'
          ':ttln:$ttln'
          ':ttr:1:ccd:true'
          ':sharedKeyEnc:abc:pubKeyCS:123'
          ':encKeyName:ekn:encAlgo:ea:ivNonce:ivn'
          ':skeEncKeyName:ske_ekn:skeEncAlgo:ske_ea'
          ':@bob:test.test@alice'
          ':Hi Bob, Alice here');
    });
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir, {String? atsign}) async {
  AtSecondaryServerImpl.getInstance().currentAtSign = atsign ?? '@bob';
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign)!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  hiveKeyStore.commitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(atsign ?? '@bob', commitLogPath: storageDir);
  await AtAccessLogManagerImpl.getInstance()
      .getAccessLog(atsign ?? '@bob', accessLogPath: storageDir);
  var notificationInstance = AtNotificationKeystore.getInstance();
  notificationInstance.currentAtSign = atsign ?? '@bob';
  await notificationInstance.init(storageDir);
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  AtNotificationMap.getInstance().clear();
  await AtNotificationKeystore.getInstance().close();
  if (isExists) {
    await Directory('test/hive').delete(recursive: true);
  }
}
