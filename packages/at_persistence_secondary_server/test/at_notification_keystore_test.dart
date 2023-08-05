import 'dart:io';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  setUp(() async => await setUpFunc(storageDir));
  group('A group of notification keystore impl tests', () {
    test('test put and get', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var commonsMetadata = Metadata()
        ..ttl = 100
        ..ttb = 200
        ..ttr = 3600
        ..ccd = true
        ..isBinary = false
        ..isEncrypted = true
        ..dataSignature = 'dataSignature'
        ..pubKeyCS = 'pubKeyChecksum'
        ..sharedKeyEnc = 'sharedKeyEncrypted'
        ..encoding = 'someEncoding'
        ..encKeyName = 'someEncKeyName'
        ..encAlgo = 'AES/CTR/PKCS7Padding'
        ..ivNonce = 'someIvNonce'
        ..skeEncKeyName = 'someSkeEncKeyName'
        ..skeEncAlgo = 'someSkeEncAlgo';
      var atMetaData = AtMetaData.fromCommonsMetadata(commonsMetadata);
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..id = '123'
            ..atMetaData = atMetaData)
          .build();
      await keyStore.put(atNotification.id, atNotification);
      final value = await keyStore.get(atNotification.id);
      expect(value, isNotNull);
      expect(value!.id, '123');
      expect(value.atMetadata?.skeEncKeyName, commonsMetadata.skeEncKeyName);
      expect(value.atMetadata?.toCommonsMetadata(), commonsMetadata);
    });
    test('test remove', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..id = '123')
          .build();
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.remove(atNotification.id);
      final value = await keyStore.get(atNotification.id);
      expect(value, isNull);
    });
    test('test delete expired keys - key expired', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 100
            ..id = '123')
          .build();
      sleep(Duration(milliseconds: 150));
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.deleteExpiredKeys();
      final value = await keyStore.get(atNotification.id);
      expect(value, isNull);
    });
    test('test delete expired keys - key not expired', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 1000
            ..id = '123')
          .build();
      sleep(Duration(milliseconds: 150));
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.deleteExpiredKeys();
      final value = await keyStore.get(atNotification.id);
      expect(value, isNotNull);
      expect(value!.id, '123');
    });
    test('test get expired keys - multiple keys expired', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification_1 = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 100
            ..id = '111')
          .build();
      var atNotification_2 = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..ttl = 1000
            ..id = '222')
          .build();
      var atNotification_3 = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..ttl = 75
            ..id = '333')
          .build();
      sleep(Duration(milliseconds: 150));
      await keyStore.put(atNotification_1.id, atNotification_1);
      await keyStore.put(atNotification_2.id, atNotification_2);
      await keyStore.put(atNotification_3.id, atNotification_3);
      var expiredKeys = await keyStore.getExpiredKeys();
      expect(2, expiredKeys.length);
      expect('111', expiredKeys.elementAt(0));
      expect('333', expiredKeys.elementAt(1));
    });
    test('test get expired keys - no keys expired', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification_1 = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111')
          .build();
      var atNotification_2 = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..ttl = 4000
            ..id = '222')
          .build();
      var atNotification_3 = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..ttl = 5000
            ..id = '333')
          .build();
      await keyStore.put(atNotification_1.id, atNotification_1);
      await keyStore.put(atNotification_2.id, atNotification_2);
      await keyStore.put(atNotification_3.id, atNotification_3);
      var expiredKeys = await keyStore.getExpiredKeys();
      expect(0, expiredKeys.length);
    });
  });

  group(
      'A group of tests to verify notification getNotificationsAfterTimestamp optimization',
      () {
    setUp(() async => await setUpFunc(storageDir));
    test(
        'A test to verify getNotificationsAfterTimestamp when given timestamp matches the notification',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);
      var notificationsFromTimestamp =
          firstNotification.notificationDateTime!.millisecondsSinceEpoch;
      await Future.delayed(Duration(seconds: 2));
      var secondNotification = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..id = '222'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(secondNotification.id, secondNotification);
      var atNotification_3 = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..id = '333'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(atNotification_3.id, atNotification_3);
      var notificationsList = await keyStore.getNotificationsAfterTimestamp(
          notificationsFromTimestamp, [NotificationType.received]);
      expect(notificationsList.length, 2);
      AtNotification atNotification = notificationsList[0];
      expect(atNotification.id, '222');
      expect(atNotification.toAtSign, '@charlie');
      expect(atNotification.fromAtSign, '@alice');

      atNotification = notificationsList[1];
      expect(atNotification.id, '333');
      expect(atNotification.toAtSign, '@dave');
      expect(atNotification.fromAtSign, '@alice');
    });

    test(
        'A test to verify getNotificationsAfterTimestamp when given timestamp does not match with notifications in the keystore',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);
      var notificationsFromTimestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch;
      await Future.delayed(Duration(seconds: 2));
      var secondNotification = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..ttl = 4000
            ..id = '222'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(secondNotification.id, secondNotification);
      var thirdNotification = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..ttl = 5000
            ..id = '333'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(thirdNotification.id, thirdNotification);
      var notificationsList = await keyStore.getNotificationsAfterTimestamp(
          notificationsFromTimestamp, [NotificationType.received]);
      expect(notificationsList.length, 2);
      AtNotification atNotification = notificationsList[0];
      expect(atNotification.id, '222');
      expect(atNotification.toAtSign, '@charlie');
      expect(atNotification.fromAtSign, '@alice');

      atNotification = notificationsList[1];
      expect(atNotification.id, '333');
      expect(atNotification.toAtSign, '@dave');
      expect(atNotification.fromAtSign, '@alice');
    });

    test(
        'A test to verify getNotificationsAfterTimestamp when in-between notifications are deleted',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);
      var notificationsFromTimestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch;
      await Future.delayed(Duration(seconds: 2));
      var secondNotification = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..ttl = 4000
            ..id = '222'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(secondNotification.id, secondNotification);
      var thirdNotification = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..ttl = 5000
            ..id = '333'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(thirdNotification.id, thirdNotification);
      await keyStore.remove('222');
      var notificationResponseList = await keyStore
          .getNotificationsAfterTimestamp(
              notificationsFromTimestamp, [NotificationType.received]);
      expect(notificationResponseList.length, 1);
      expect(notificationResponseList.first.id, '333');
    });

    test(
        'A test to verify getNotificationsAfterTimestamp returns empty list when there are no matching notification',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);
      var notificationsFromTimestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch;
      await Future.delayed(Duration(seconds: 2));
      var notificationResponseList = await keyStore
          .getNotificationsAfterTimestamp(
              notificationsFromTimestamp, [NotificationType.received]);
      expect(notificationResponseList.length, 0);
    });

    test(
        'A test to verify getNotificationAfterTimestamp when timestamp matches all notifications',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var notificationsFromTimestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch;
      await Future.delayed(Duration(seconds: 2));
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);

      var secondNotification = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..ttl = 4000
            ..id = '222'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(secondNotification.id, secondNotification);

      var thirdNotification = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..ttl = 5000
            ..id = '333'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(thirdNotification.id, thirdNotification);

      var notificationsList = await keyStore.getNotificationsAfterTimestamp(
          notificationsFromTimestamp, [NotificationType.received]);
      expect(notificationsList.length, 3);
      AtNotification atNotification = notificationsList[0];
      expect(atNotification.id, '111');
      expect(atNotification.toAtSign, '@bob');
      expect(atNotification.fromAtSign, '@alice');

      atNotification = notificationsList[1];
      expect(atNotification.id, '222');
      expect(atNotification.toAtSign, '@charlie');
      expect(atNotification.fromAtSign, '@alice');

      atNotification = notificationsList[2];
      expect(atNotification.id, '333');
      expect(atNotification.toAtSign, '@dave');
      expect(atNotification.fromAtSign, '@alice');
    });

    test(
        'A test to verify getNotificationAfterTimestamp when timestamp matches the last notifications',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);

      var secondNotification = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..ttl = 4000
            ..id = '222'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(secondNotification.id, secondNotification);

      var notificationsFromTimestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch;
      await Future.delayed(Duration(seconds: 2));
      var thirdNotification = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..ttl = 5000
            ..id = '333'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(thirdNotification.id, thirdNotification);

      var notificationsList = await keyStore.getNotificationsAfterTimestamp(
          notificationsFromTimestamp, [NotificationType.received]);
      expect(notificationsList.length, 1);
      AtNotification atNotification = notificationsList[0];
      expect(atNotification.id, '333');
      expect(atNotification.toAtSign, '@dave');
      expect(atNotification.fromAtSign, '@alice');
    });

    test(
        'A test to verify empty list is returned when notification keystore is empty',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var list = await keyStore.getNotificationsAfterTimestamp(
          DateTime.now().toUtc().millisecondsSinceEpoch,
          [NotificationType.received]);
      expect(list, isEmpty);
    });

    test(
        'A test to verify when only one matching entry exists in notification keystore',
        () async {
      var keyStore = AtNotificationKeystore.getInstance();
      int timeStamp = DateTime.now().toUtc().millisecondsSinceEpoch;
      await Future.delayed(Duration(milliseconds: 100));
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);
      var notificationsList = await keyStore.getNotificationsAfterTimestamp(
          timeStamp, [NotificationType.received]);
      expect(notificationsList.length, 1);
      AtNotification atNotification = notificationsList[0];
      expect(atNotification.id, '111');
      expect(atNotification.toAtSign, '@bob');
      expect(atNotification.fromAtSign, '@alice');
    });

    test('A test to verify expired notifications are not returned', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var notificationsFromTimestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch;
      await Future.delayed(Duration(milliseconds: 1));
      var firstNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..ttl = 3000
            ..id = '111'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(firstNotification.id, firstNotification);

      var secondNotification = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = '@alice'
            ..ttl = 4000
            ..id = '222'
            ..ttl = 1
            ..type = NotificationType.received)
          .build();
      await keyStore.put(secondNotification.id, secondNotification);
      await Future.delayed(Duration(milliseconds: 2));
      var thirdNotification = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = '@alice'
            ..ttl = 5000
            ..id = '333'
            ..type = NotificationType.received)
          .build();
      await keyStore.put(thirdNotification.id, thirdNotification);

      var notificationResponseList = await keyStore
          .getNotificationsAfterTimestamp(
              notificationsFromTimestamp, [NotificationType.received]);
      expect(notificationResponseList.length, 2);
      expect(notificationResponseList[0].id, '111');
      expect(notificationResponseList[0].fromAtSign, '@alice');
      expect(notificationResponseList[0].toAtSign, '@bob');
      expect(notificationResponseList[1].id, '333');
      expect(notificationResponseList[1].fromAtSign, '@alice');
      expect(notificationResponseList[1].toAtSign, '@dave');
    });
  });
  try {
    tearDown(() async => await tearDownFunc());
  } on Exception catch (e) {
    print('error in tear down:${e.toString()}');
  }
}

Future<AtNotificationKeystore> setUpFunc(storageDir) async {
  var notificationKeystoreInstance = AtNotificationKeystore.getInstance();
  notificationKeystoreInstance.currentAtSign = '@alice';
  await notificationKeystoreInstance.init('$storageDir/${Uuid().v4()}');
  return notificationKeystoreInstance;
}

Future<void> tearDownFunc() async {
  print('tear down');
  await AtNotificationKeystore.getInstance().close();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
