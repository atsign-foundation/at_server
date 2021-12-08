import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() async {
  var storageDir = Directory.current.path + '/test/hive';
  setUp(() async => await setUpFunc(storageDir));
  group('A group of notification keystore impl tests', () {
    test('test put and get', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = '@alice'
            ..id = '123')
          .build();
      await keyStore.put(atNotification.id, atNotification);
      final value = await keyStore.get(atNotification.id);
      expect(value, isNotNull);
      expect(value!.id, '123');
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
