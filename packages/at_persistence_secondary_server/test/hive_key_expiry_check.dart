import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  String atsign = '@test_user_1';
  var keyStore;

  group('test scenarios for expired keys', () {
    setUp(() async {
      var keyStoreManager = await getKeystoreManager(storageDir, atsign);
      keyStore = keyStoreManager.getKeyStore();
      assert(keyStore != null);
    });

    test('fetch expired key returns throws exception', () async {
      String key = '123$atsign';
      var atData = AtData()..data = 'abc';
      await keyStore?.put(key, atData, time_to_live: 10 * 1000);
      var atDataResponse = await keyStore?.get(key);
      print(atDataResponse?.data);
      assert(atDataResponse?.data == 'abc');
      stdout.writeln('Sleeping for 1min10s');
      var expiredKeyData = await Future.delayed(
          Duration(minutes: 1, seconds: 10), () => getKey(keyStore, key));
      expect(
          () async => expiredKeyData,
          throwsA(predicate((e) =>
              e.toString().contains('123$atsign does not exist in keystore'))));
      print(expiredKeyData);
    }, timeout: Timeout(Duration(minutes: 2)));

    test('ensure expired keys deletion entry is not added to commitLog',
        () async {
      String key = 'no_commit_log_test$atsign';
      var atData = AtData()..data = 'randomDataString';
      await keyStore?.put(key, atData, time_to_live: 2000);
      // ensure key is inserted
      expect((await keyStore.get(key)).data, atData.data);
      await Future.delayed(Duration(seconds: 4));
      await keyStore?.deleteExpiredKeys();
      // ensure that the key is expired
      expect(
          () async => await keyStore.get(key),
          throwsA(predicate((e) => e.toString().contains(
              'no_commit_log_test@test_user_1 does not exist in keystore'))));

      expect(keyStore?.commitLog.getSize(), 1); //commitLog has 1 entries; indicating that
      // deletion of expired keys has NOT been added to the commitLog
    });

    test(
        'manually deleted keys add a commitEntry to commitLog',
        () async {
      // -----------------insert key 1 that expires in 100ms
      String key1 = 'no_commit_1$atsign';
      var atData = AtData()..data = 'randomDataString1';
      int seqNum = await keyStore?.put(key1, atData, time_to_live: 100);
      await Future.delayed(Duration(seconds: 1));
      await keyStore?.deleteExpiredKeys();
      // ensure that the key is expired
      expect(
          () async => await keyStore.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));
      // ------------------insert key2 that is manually deleted
      String key2 = 'no_commit_2$atsign';
      atData = AtData()..data = 'randomDataString2';
      seqNum = await keyStore?.put(key2, atData);
      seqNum = await keyStore?.remove(key2);
      // ensure that the key does not exist in keystore
      expect(
          () async => await keyStore.get(key2),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));

      expect(keyStore?.commitLog.getSize(), 1); //commitLog has 1 entry; indicating that
      // deletion of expired keys has NOT been added to the commitLog but the manual
          // delete operation added a commit to the commitLog
    });

    tearDown(() async => await tearDownFunc());
  });
}

Future<String?> getKey(keyStore, key) async {
  AtData? atData = await keyStore.get(key);
  return atData?.data;
}

Future<SecondaryKeyStoreManager> getKeystoreManager(storageDir, atsign) async {
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atsign)!;
  var manager = secondaryPersistenceStore.getHivePersistenceManager()!;
  await manager.init(storageDir);
  manager.scheduleKeyExpireTask(1);

  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  var keyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  var commitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(atsign, commitLogPath: storageDir, enableCommitId: true);
  // await commitLogKeyStore.init(storageDir);
  // await commitLogKeyStore.initialize();
  keyStore.commitLog = commitLog;
  keyStoreManager.keyStore = keyStore;
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
