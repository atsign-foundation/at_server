import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:test/test.dart';

var storageDir = '${Directory.current.path}/test/hive';
late AtKeyValueStore keyValueStore;
void main() async {
  group('Verify blocklist configuration behaviour', () {
    setUp(() async => await setUpFunc(storageDir));

    test('test for adding data to blocklist', () async {
      var atsignsToBeBlocked = {'@alice', '@bob'};
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      var result = await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      expect(result, 'success');
    });

    test('test for fetching blocklist', () async {
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      var atsignsToBeBlocked = {'@alice', '@bob'};
      await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      var result = await atConfigInstance.getBlockList();
      expect(result, atsignsToBeBlocked);
    });

    test('test for removing blocklist data', () async {
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      var atsignsToBeBlocked = {'@alice', '@bob', '@charlie'};
      await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      var atsignsToBeUnblocked = {'@alice', '@bob'};
      var result =
          await atConfigInstance.removeFromBlockList(atsignsToBeUnblocked);
      expect(result, 'success');
      // get block list
      var blockList = await atConfigInstance.getBlockList();
      expect(blockList, {'@charlie'});
    });

    test('test for removing non existing data from blocklist', () async {
      var data = {'@alice', '@bob'};
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      await atConfigInstance.addToBlockList(data);
      var removeData = {'@colin'};
      var result = await atConfigInstance.removeFromBlockList(removeData);
      expect(result, 'success');
    });

    test('test for removing empty data', () async {
      var removeData = <String>{};
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList(removeData),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    test('test for removing null data', () async {
      var atConfigInstance = AtConfig(keyValueStore, '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList({}),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    tearDown(() async => await tearDownFunc());
  });
}

late HiveAtPersistenceFactory _atConfigTestFactory;

Future<void> setUpFunc(String storageDir) async {
  _atConfigTestFactory = HiveAtPersistenceFactory();
  final bundle = await _atConfigTestFactory.initialize(
    '@test_user_1',
    HivePersistenceConfig(
      storagePath: storageDir,
      commitLogPath: storageDir,
      accessLogPath: storageDir,
      notificationStoragePath: storageDir,
    ),
  );
  keyValueStore = bundle.keyValueStore;
}

Future<void> tearDownFunc() async {
  await _atConfigTestFactory.close();
  var dir = Directory('test/hive/');
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}
