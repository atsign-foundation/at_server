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
    test('test expired keys - key expired', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification = (AtNotificationBuilder()
        ..toAtSign = '@bob'
        ..fromAtSign = '@alice'
        ..ttl=100
        ..id = '123')
          .build();
      sleep(Duration(milliseconds: 150));
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.deleteExpiredKeys();
      final value = await keyStore.get(atNotification.id);
      expect(value, isNull);
    });
    test('test expired keys - key not expired', () async {
      var keyStore = AtNotificationKeystore.getInstance();
      var atNotification = (AtNotificationBuilder()
        ..toAtSign = '@bob'
        ..fromAtSign = '@alice'
        ..ttl=1000
        ..id = '123')
          .build();
      sleep(Duration(milliseconds: 150));
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.deleteExpiredKeys();
      final value = await keyStore.get(atNotification.id);
      expect(value, isNotNull);
      expect(value!.id, '123');
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
  await AtNotificationKeystore.getInstance().close();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
