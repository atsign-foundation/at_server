import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = Directory.current.path + '/test/hive';
  setUp(() async => await setUpFunc(storageDir));

  test('test for adding data to blocklist', () async {
    var atConfigInstance = AtConfig.getInstance();
    var keyStoreManager = SecondaryKeyStoreManager.getInstance();
    keyStoreManager.init();
    var data = {'@alice', '@bob'};
    var result = await atConfigInstance.addToBlockList(data);
    expect(result, 'success');
  });

  test('test for fetching blocklist', () async {
    var atConfigInstance = AtConfig.getInstance();
    var keyStoreManager = SecondaryKeyStoreManager.getInstance();
    keyStoreManager.init();
    var data = {'@alice', '@bob'};
    await atConfigInstance.addToBlockList(data);
    var result = await atConfigInstance.getBlockList();
    expect(result, {'@alice', '@bob'});
  });

  test('test for removing blocklist data', () async {
    var atConfigInstance = AtConfig.getInstance();
    var keyStoreManager = SecondaryKeyStoreManager.getInstance();
    keyStoreManager.init();
    var data = {'@alice', '@bob'};
    await atConfigInstance.addToBlockList(data);
    var result = await atConfigInstance.removeFromBlockList(data);
    expect(result, 'success');
  });

  test('test for removing non existing data from blocklist', () async {
    var atConfigInstance = AtConfig.getInstance();
    var keyStoreManager = SecondaryKeyStoreManager.getInstance();
    keyStoreManager.init();
    var data = {'@alice', '@bob'};
    await atConfigInstance.addToBlockList(data);
    var removeData = {'@colin'};
    var result = await atConfigInstance.removeFromBlockList(removeData);
    expect(result, 'success');
  });

  test('test for removing empty data', () async {
    var atConfigInstance = AtConfig.getInstance();
    var keyStoreManager = SecondaryKeyStoreManager.getInstance();
    keyStoreManager.init();
    var removeData = <String>{};
    expect(() async => await atConfigInstance.removeFromBlockList(removeData),
        throwsA(predicate((e) => e is AssertionError)));
  });

  test('test for removing null data', () async {
    var atConfigInstance = AtConfig.getInstance();
    var keyStoreManager = SecondaryKeyStoreManager.getInstance();
    keyStoreManager.init();
    expect(() async => await atConfigInstance.removeFromBlockList(null),
        throwsA(predicate((e) => e is AssertionError)));
  });

  try {
    tearDown(() async => await tearDownFunc());
  } on Exception catch (e) {
    print('error in tear down:${e.toString()}');
  }
}

void setUpFunc(storageDir) async {
  await CommitLogKeyStore.getInstance()
      .init('commit_log_@test_user_2', storageDir);
  var persistenceManager = HivePersistenceManager.getInstance();
  await persistenceManager.init('@test_user_1', storageDir);
}

void tearDownFunc() async {
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    await Directory('test/hive/').deleteSync(recursive: true);
  }
}