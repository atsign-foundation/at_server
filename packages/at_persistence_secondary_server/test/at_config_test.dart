import 'dart:convert';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/config/configuration.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  setUp(() async => await setUpFunc(storageDir));

  test('test for adding data to blocklist', () async {
    var data = {'@alice', '@bob'};
    var atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog('@test_user_1'),
        '@test_user_1');
    var result = await atConfigInstance.addToBlockList(data);
    expect(result, 'success');
  });

  test('test for fetching blocklist', () async {
    var atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog('@test_user_1'),
        '@test_user_1');
    var data = {'@alice', '@bob'};
    await atConfigInstance.addToBlockList(data);
    var result = await atConfigInstance.getBlockList();
    expect(result, {'@alice', '@bob'});
  }, timeout: Timeout(Duration(minutes: 10)));

  test('test for removing blocklist data', () async {
    var atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog('@test_user_1'),
        '@test_user_1');
    var data = {'@alice', '@bob'};
    await atConfigInstance.addToBlockList(data);
    var result = await atConfigInstance.removeFromBlockList(data);
    expect(result, 'success');
  });

  test('test for removing non existing data from blocklist', () async {
    var data = {'@alice', '@bob'};
    var atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog('@test_user_1'),
        '@test_user_1');
    await atConfigInstance.addToBlockList(data);
    var removeData = {'@colin'};
    var result = await atConfigInstance.removeFromBlockList(removeData);
    expect(result, 'success');
  });

  test('test for removing empty data', () async {
    var removeData = <String>{};
    var atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog('@test_user_1'),
        '@test_user_1');
    expect(() async => await atConfigInstance.removeFromBlockList(removeData),
        throwsA(predicate((dynamic e) => e is AssertionError)));
  });

  test('test for removing null data', () async {
    var atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog('@test_user_1'),
        '@test_user_1');
    expect(() async => await atConfigInstance.removeFromBlockList({}),
        throwsA(predicate((dynamic e) => e is AssertionError)));
  });

  test('verify backwards compatibility of blocklist with config key', () async {
    AtConfig atConfig = AtConfig(
        await AtCommitLogManagerImpl.getInstance().getCommitLog('@test_user_1'),
        '@test_user_1');
    LazyBox box = atConfig.persistenceManager.getBox() as LazyBox;
    List<String> blockedAtsigns = [
      '@blocked_user_1',
      '@blocked_user_2',
      '@blocked_user_3'
    ];
    var blockedConfig = Configuration(blockedAtsigns);
    AtData atData = AtData()..data = jsonEncode(blockedConfig);
    atData = HiveKeyStoreHelper.getInstance().prepareDataForKeystoreOperation(atData);
    await box.put(atConfig.oldConfigKey, atData);
    // fetch the data that has been put into the keystore using the new config key
    var blockList = await atConfig.getBlockList();
    expect(blockList.toList(), blockedAtsigns);
    // verify that the new config key has been put into the keystore
    assert(box.containsKey(atConfig.configKey));
    // verify that the oldConfigKey has been deleted
    box.containsKey(atConfig.oldConfigKey);
  });

  try {
    tearDown(() async => await tearDownFunc());
  } on Exception catch (e) {
    print('error in tear down:${e.toString()}');
  }
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@test_user_1', commitLogPath: storageDir);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@test_user_1')!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive/').deleteSync(recursive: true);
  }
}
