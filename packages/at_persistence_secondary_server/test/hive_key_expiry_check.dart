import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive/';

  group('test scenarios for expired keys - CASE: optimizeCommits set to TRUE',
      () {
    String atsign = '@test_user_1';
    HiveKeystore? keyStore;
    late AtCommitLog commitLog;

    setUp(() async {
      var keyStoreManager =
          await getKeystoreManager(storageDir, atsign, optimizeCommits: true);
      keyStore = keyStoreManager.getKeyStore() as HiveKeystore?;
      assert(keyStore != null);
      commitLog = keyStore!.commitLog as AtCommitLog;
    });

    test('fetch expired key returns throws exception', () async {
      String key = '123.g1t1$atsign';
      var atData = AtData()..data = 'abc';
      await keyStore?.put(key, atData, time_to_live: 5);
      var atDataResponse = await keyStore?.get(key);
      assert(atDataResponse!.data == 'abc');
      await keyStore!.deleteExpiredKeys(skipCommit: true);
      expect(
          () async => getKey(keyStore, key),
          throwsA(predicate((e) =>
              e.toString().contains('$key does not exist in keystore'))));
    }, timeout: Timeout(Duration(minutes: 1)));

    test('ensure expired keys deletion does NOT add entry to commitLog',
        () async {
      String key = 'no_commit_log_test.g1t2$atsign';
      var atData = AtData()..data = 'randomDataString';
      await keyStore?.put(key, atData, time_to_live: 2);
      expect((await keyStore?.get(key))?.data, atData.data);

      await keyStore?.deleteExpiredKeys(skipCommit: true);
      await Future.delayed(Duration(seconds: 2));
      // ensure that the key is expired
      expect(
          () async => await keyStore!.get(key),
          throwsA(predicate((e) =>
              e.toString().contains('$key does not exist in keystore'))));
      expect(commitLog.getLatestCommitEntry(key), null);

      // expects 0 commitEntries as when skipCommits is enabled, that does not
      // add new commitEntries for deletion of expired keys and also removes
      // the UPDATE_ALL commitEntry created while deletion
      expect(commitLog.entriesCount(), 0);
    });

    test('manually deleted keys add a commitEntry to commitLog', () async {
      // insert key 1 that expires in 100ms
      String key1 = 'no_commit_1.g1t3$atsign';
      var atData = AtData()..data = 'randomDataString1';
      await keyStore?.put(key1, atData, time_to_live: 2);

      // insert key2 and manually delete the key
      String key2 = 'no_commit_2.g1t3$atsign';
      atData = AtData()..data = 'randomDataString2';
      await keyStore!.put(key2, atData);
      await keyStore!.remove(key2);

      await keyStore!.deleteExpiredKeys(skipCommit: true);
      await Future.delayed(Duration(seconds: 2));

      // ensure that key1 and key2 do NOT exist in the keystore
      expect(() async => await keyStore!.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));
      expect(() async => await keyStore!.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));

      // key1 should NOT have a commitEntry as it was removed by deletedExpiredKeys job
      expect(commitLog.getLatestCommitEntry(key1), null);
      expect(commitLog.getLatestCommitEntry(key2)!.operation, CommitOp.DELETE);

      // 1 commit entry available belongs to the key created and deleted manually
      expect(keyStore!.commitLog!.entriesCount(), 1);
    });

    test('validate commit log with keys that are expired and deleted',
        () async {
      // insert key 1 that expires in 10ms
      String key1 = 'expired_key1.g1t4$atsign';
      var atData = AtData()..data = 'randomDataString1';
      await keyStore!.put(key1, atData, time_to_live: 3);

      // insert key2 and manually delete the key
      String key2 = 'delete_key1.g1t4$atsign';
      atData = AtData()..data = 'randomDataString2';
      await keyStore!.put(key2, atData);
      await keyStore!.remove(key2);

      // insert key3 that does NOT expire and NOT deleted
      String key3 = 'normal_key.g1t4$atsign';
      atData = AtData()..data = 'randomDataString3';
      await keyStore!.put(key3, atData);

      await keyStore!.deleteExpiredKeys(skipCommit: true);
      await Future.delayed(Duration(seconds: 2));

      // key1 and key should NOT be in the keystore as they have been removed
      expect(() async => await keyStore!.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));
      expect(() async => await keyStore!.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));

      // validate commitOp's for respective keys
      expect(commitLog.getLatestCommitEntry(key1), null);
      expect(commitLog.getLatestCommitEntry(key2)!.operation, CommitOp.DELETE);
      expect(commitLog.getLatestCommitEntry(key3)!.operation, CommitOp.UPDATE);

      expect(commitLog.getLatestCommitEntry(key2)!.commitId, 2);
      expect(commitLog.getLatestCommitEntry(key3)!.commitId, 3);

      // Expected num of commit entries is 2 - key 2 and key 3 should have commit entries
      expect(keyStore!.commitLog!.entriesCount(), 2);
    });

    tearDown(() async => await tearDownFunc());
  });

  group('test scenarios for expired keys - CASE: optimizeCommits set to FALSE',
      () {
    String atsign = '@test_user_2';
    HiveKeystore? keyStore;
    late AtCommitLog commitLog;

    setUp(() async {
      var keyStoreManager =
          await getKeystoreManager(storageDir, atsign, optimizeCommits: false);
      keyStore = keyStoreManager.getKeyStore() as HiveKeystore?;
      assert(keyStore != null);
      commitLog = keyStore!.commitLog as AtCommitLog;
    });

    test('ensure expired keys deletion entry is added to commitLog', () async {
      String key = 'commit_test.g2t1$atsign';
      var atData = AtData()..data = 'randomDataString';
      await keyStore!.put(key, atData, time_to_live: 2000);
      // ensure key is inserted
      expect((await keyStore!.get(key))!.data, atData.data);

      await Future.delayed(Duration(seconds: 4));
      await keyStore!.deleteExpiredKeys();
      // ensure that the key is expired
      expect(
          () async => await keyStore!.get(key),
          throwsA(predicate((e) =>
              e.toString().contains('$key does not exist in keystore'))));

      expect(commitLog.getLatestCommitEntry(key)!.operation, CommitOp.DELETE);
      expect(commitLog.entriesCount(), 1);
    });

    test('manually deleted keys add a commitEntry to commitLog', () async {
      // insert key 1 that expires in 100ms
      String key1 = 'no_commit_3.g2t2$atsign';
      var atData = AtData()..data = 'randomDataString1';
      await keyStore!.put(key1, atData, time_to_live: 100);
      await Future.delayed(Duration(seconds: 1));
      await keyStore!.deleteExpiredKeys();
      // ensure that the key is expired
      expect(() async => await keyStore!.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));
      expect(commitLog.getLatestCommitEntry(key1)!.operation, CommitOp.DELETE);

      // insert key2 that is manually deleted
      String key2 = 'no_commit_4.g2t2$atsign';
      atData = AtData()..data = 'randomDataString2';
      await keyStore!.put(key2, atData);
      await keyStore!.remove(key2);
      // ensure that the second key does not exist in keystore
      expect(() async => await keyStore!.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));
      expect(commitLog.getLatestCommitEntry(key2)!.operation, CommitOp.DELETE);

      expect(keyStore!.commitLog!.entriesCount(), 2);
    });

    tearDown(() async => await tearDownFunc());
  });
}

Future<String?> getKey(keyStore, key) async {
  AtData? atData = await keyStore.get(key);
  return atData?.data;
}

Future<SecondaryKeyStoreManager> getKeystoreManager(storageDir, atsign,
    {required bool optimizeCommits}) async {
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atsign)!;
  var manager = secondaryPersistenceStore.getHivePersistenceManager()!;
  await manager.init(storageDir);
  manager.scheduleKeyExpireTask(null,
      runTimeInterval: Duration(seconds: 10), skipCommits: optimizeCommits);
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  var keyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  var commitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(atsign, commitLogPath: storageDir, enableCommitId: true);
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
