import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = Directory.current.path + '/test/hive';
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
