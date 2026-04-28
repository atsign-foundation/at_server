import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:at_secondary/src/config/configuration.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

var storageDir = '${Directory.current.path}/test/hive';
late SecondaryKeyStore keyStore;
late HivePersistenceManager persistenceManager;
void main() async {
  group('Verify blocklist configuration behaviour', () {
    setUp(() async => await setUpFunc(storageDir));

    test('test for adding data to blocklist', () async {
      var atsignsToBeBlocked = {'@alice', '@bob'};
      var atConfigInstance = AtConfig(keyStore, '@test_user_1');
      var result = await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      expect(result, 'success');
    });

    test('test for fetching blocklist', () async {
      var atConfigInstance = AtConfig(keyStore, '@test_user_1');
      var atsignsToBeBlocked = {'@alice', '@bob'};
      await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      var result = await atConfigInstance.getBlockList();
      expect(result, atsignsToBeBlocked);
    });

    test('test for removing blocklist data', () async {
      var atConfigInstance = AtConfig(keyStore, '@test_user_1');
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
      var atConfigInstance = AtConfig(keyStore, '@test_user_1');
      await atConfigInstance.addToBlockList(data);
      var removeData = {'@colin'};
      var result = await atConfigInstance.removeFromBlockList(removeData);
      expect(result, 'success');
    });

    test('test for removing empty data', () async {
      var removeData = <String>{};
      var atConfigInstance = AtConfig(keyStore, '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList(removeData),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    test('test for removing null data', () async {
      var atConfigInstance = AtConfig(keyStore, '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList({}),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    // Manually insert block-list into keystore under the old config-key
    // (bypassing keystore validation, which would reject the bare key
    // 'configKey'). Successfully fetch block-list with the new config-key
    // indicating that the migration code path is backwards compatible.
    // Verify that the old-config key has been deleted.
    test('verify backwards compatibility of blocklist with new config-key',
        () async {
      AtConfig atConfig = AtConfig(keyStore, '@test_user_1');
      List<String> blockedAtsigns = [
        '@blocked_user_1',
        '@blocked_user_2',
        '@blocked_user_3'
      ];
      var blockedConfig = Configuration(blockedAtsigns);
      AtData atData = AtData()..data = jsonEncode(blockedConfig);
      // Seed legacy state by writing under the old (validation-bypassing)
      // key directly via Hive — that's how this data ended up in the
      // keystore historically, and it's the scenario the migration path
      // exists to repair.
      LazyBox box = persistenceManager.getBox() as LazyBox;
      await box.put(atConfig.oldConfigKey, atData);
      // fetch the data that has been put into the keystore using the new config key
      var blockList = await atConfig.getBlockList();
      expect(blockList.toList(), blockedAtsigns);
      // verify that the new config key has been put into the keystore
      expect(keyStore.isKeyExists(atConfig.configKey), true);
      // verify that the oldConfigKey has been deleted
      expect(keyStore.isKeyExists(atConfig.oldConfigKey), false);
    });

    tearDown(() async => await tearDownFunc());
  });
}

late HiveAtPersistenceFactory _atConfigTestFactory;

Future<void> setUpFunc(String storageDir) async {
  _atConfigTestFactory = HiveAtPersistenceFactory();
  final bundle = (await _atConfigTestFactory.initialize(
    '@test_user_1',
    HivePersistenceConfig(
      storagePath: storageDir,
      commitLogPath: storageDir,
      accessLogPath: storageDir,
      notificationStoragePath: storageDir,
    ),
  )) as HiveAtPersistenceBundle;
  keyStore = bundle.keyStore;
  persistenceManager = bundle.hivePersistenceManager;
}

Future<void> tearDownFunc() async {
  await _atConfigTestFactory.close();
  var dir = Directory('test/hive/');
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}
