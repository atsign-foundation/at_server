import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/config/configuration.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

var storageDir = '${Directory.current.path}/test/hive';
void main() async {
  group('Verify blocklist configuration behaviour', () {
    setUp(() async => await setUpFunc(storageDir));

    test('test for adding data to blocklist', () async {
      var atsignsToBeBlocked = {'@alice', '@bob'};
      var atConfigInstance = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog('@test_user_1'),
          '@test_user_1');
      var result = await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      expect(result, 'success');
    });

    test('test for fetching blocklist', () async {
      var atConfigInstance = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog('@test_user_1'),
          '@test_user_1');
      var atsignsToBeBlocked = {'@alice', '@bob'};
      await atConfigInstance.addToBlockList(atsignsToBeBlocked);
      var result = await atConfigInstance.getBlockList();
      expect(result, atsignsToBeBlocked);
    });

    test('test for removing blocklist data', () async {
      var atConfigInstance = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog('@test_user_1'),
          '@test_user_1');
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
      var atConfigInstance = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog('@test_user_1'),
          '@test_user_1');
      await atConfigInstance.addToBlockList(data);
      var removeData = {'@colin'};
      var result = await atConfigInstance.removeFromBlockList(removeData);
      expect(result, 'success');
    });

    test('test for removing empty data', () async {
      var removeData = <String>{};
      var atConfigInstance = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog('@test_user_1'),
          '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList(removeData),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    test('test for removing null data', () async {
      var atConfigInstance = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog('@test_user_1'),
          '@test_user_1');
      expect(() async => await atConfigInstance.removeFromBlockList({}),
          throwsA(predicate((dynamic e) => e is IllegalArgumentException)));
    });

    // Manually insert block-list into keystore under the old config-key
    // Successfully fetch block-list with new config-key indicating that the code
    // is backwards compatible
    // Verify that the old-config key has been deleted
    test('verify backwards compatibility of blocklist with new config-key',
        () async {
      AtConfig atConfig = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog('@test_user_1'),
          '@test_user_1');
      LazyBox box = atConfig.persistenceManager.getBox() as LazyBox;
      List<String> blockedAtsigns = [
        '@blocked_user_1',
        '@blocked_user_2',
        '@blocked_user_3'
      ];
      var blockedConfig = Configuration(blockedAtsigns);
      AtData atData = AtData()..data = jsonEncode(blockedConfig);
      atData = HiveKeyStoreHelper.getInstance()
          .prepareDataForKeystoreOperation(atData);
      await box.put(atConfig.oldConfigKey, atData);
      // fetch the data that has been put into the keystore using the new config key
      var blockList = await atConfig.getBlockList();
      expect(blockList.toList(), blockedAtsigns);
      // verify that the new config key has been put into the keystore
      expect(box.containsKey(atConfig.configKey), true);
      // verify that the oldConfigKey has been deleted
      expect(box.containsKey(atConfig.oldConfigKey), false);
    });

    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@test_user_1', commitLogPath: storageDir);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@test_user_1')!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
  // commented this line for coverage test
  // persistenceManager.scheduleKeyExpireTask(1);
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  // closes the instance of hive keystore
  await SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@test_user_1')!
      .getHivePersistenceManager()?.close();

  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    await Directory('test/hive/').delete(recursive: true);
  }
}
