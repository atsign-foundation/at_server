import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  String atsign = '@test_user_1';
  HiveKeystore? keyStore;

  group('test scenarios for expired keys - CASE: optimizeCommits set to TRUE',
      () {
    // verifies that deletion of expired keys does NOT create/update commit entries
    setUp(() async {
      var keyStoreManager = await getKeystoreManager(storageDir, atsign, optimizeCommits: true);
      keyStore = keyStoreManager.getKeyStore() as HiveKeystore?;
      assert(keyStore != null);
    });

    test('fetch expired key returns throws exception', () async {
      String key = '123$atsign';
      var atData = AtData()..data = 'abc';
      await keyStore?.put(key, atData, time_to_live: 5 * 1000);
      var atDataResponse = await keyStore?.get(key);
      assert(atDataResponse?.data == 'abc');
      stdout.writeln('Sleeping for 23s');
      await Future.delayed(Duration(seconds: 23));
      expect(
          () async => getKey(keyStore, key),
          throwsA(predicate((e) =>
              e.toString().contains('123$atsign does not exist in keystore'))));
    }, timeout: Timeout(Duration(minutes: 1)));

    test('ensure expired keys deletion entry is not added to commitLog',
        () async {
      String key = 'no_commit_log_test$atsign';
      var atData = AtData()..data = 'randomDataString';
      await keyStore?.put(key, atData, time_to_live: 2000);
      expect((await keyStore?.get(key))?.data, atData.data);

      await Future.delayed(Duration(seconds: 4));
      await keyStore?.deleteExpiredKeys(optimizeCommits: true);
      // ensure that the key is expired
      expect(
          () async => await keyStore?.get(key),
          throwsA(predicate((e) => e.toString().contains(
              'no_commit_log_test@test_user_1 does not exist in keystore'))));
      AtCommitLog? commitLog = keyStore?.commitLog as AtCommitLog;
      expect(
          commitLog.getLatestCommitEntry(key)?.operation, CommitOp.UPDATE_ALL);
      // the latest commit entry is one with an UPDATE_ALL op which indicates that
      // the deleteExpiredKeys did not add a DELETE commitEntry to the commitLog
      expect(commitLog.entriesCount(), 1);
    });

    test('manually deleted keys add a commitEntry to commitLog', () async {
      AtCommitLog? commitLog = keyStore?.commitLog as AtCommitLog;
      // -----------------insert key 1 that expires in 100ms
      String key1 = 'no_commit_1$atsign';
      var atData = AtData()..data = 'randomDataString1';
      int? seqNum = await keyStore?.put(key1, atData, time_to_live: 100);
      print(seqNum);
      await Future.delayed(Duration(seconds: 1));
      await keyStore?.deleteExpiredKeys(optimizeCommits: true);
      // ensure that the key is expired
      expect(() async => await keyStore?.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));
      expect(
          commitLog.getLatestCommitEntry(key1)?.operation, CommitOp.UPDATE_ALL);
      // ------------------insert key2 that is manually deleted
      String key2 = 'no_commit_2$atsign';
      atData = AtData()..data = 'randomDataString2';
      seqNum = await keyStore?.put(key2, atData);
      print(seqNum);
      seqNum = await keyStore?.remove(key2);
      // ensure that the second key does not exist in keystore
      expect(() async => await keyStore?.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));
      expect(commitLog.getLatestCommitEntry(key2)?.operation, CommitOp.DELETE);
      // the latest commitEntry for key2 has CommitOp.DELETE indicating that the commits are not being
      // skipped for the keys that are not deleted as part of deleteExpiredKeys()
      expect(keyStore?.commitLog?.entriesCount(), 2);
    });

    tearDown(() async => await tearDownFunc());
  });

  group('test scenarios for expired keys - CASE: optimizeCommits set to FALSE',
      () {
        // verifies that deletion of expired keys creates/updates commit entries
        setUp(() async {
      var keyStoreManager = await getKeystoreManager(storageDir, atsign, optimizeCommits: false);
      keyStore = keyStoreManager.getKeyStore() as HiveKeystore?;
      assert(keyStore != null);
    });

    test('ensure expired keys deletion entry is not added to commitLog',
        () async {
      AtCommitLog? commitLog = keyStore?.commitLog as AtCommitLog;
      String key = 'commit_test$atsign';
      var atData = AtData()..data = 'randomDataString';
      await keyStore?.put(key, atData, time_to_live: 2000);
      // ensure key is inserted
      expect((await keyStore?.get(key))?.data, atData.data);

      await Future.delayed(Duration(seconds: 4));
      await keyStore?.deleteExpiredKeys();
      // ensure that the key is expired
      expect(
          () async => await keyStore?.get(key),
          throwsA(predicate((e) =>
              e.toString().contains('$key does not exist in keystore'))));

      expect(commitLog.getLatestCommitEntry(key)?.operation, CommitOp.DELETE);
      expect(commitLog.entriesCount(), 1);
    });

    test('manually deleted keys add a commitEntry to commitLog', () async {
      AtCommitLog? commitLog = keyStore?.commitLog as AtCommitLog;
      // -----------------insert key 1 that expires in 100ms
      String key1 = 'no_commit_3$atsign';
      var atData = AtData()..data = 'randomDataString1';
      int? seqNum = await keyStore?.put(key1, atData, time_to_live: 100);
      print(seqNum);
      await Future.delayed(Duration(seconds: 1));
      await keyStore?.deleteExpiredKeys();
      // ensure that the key is expired
      expect(() async => await keyStore?.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));
      expect(commitLog.getLatestCommitEntry(key1)?.operation, CommitOp.DELETE);
      // ------------------insert key2 that is manually deleted
      String key2 = 'no_commit_4$atsign';
      atData = AtData()..data = 'randomDataString2';
      seqNum = await keyStore?.put(key2, atData);
      print(seqNum);
      seqNum = await keyStore?.remove(key2);
      // ensure that the second key does not exist in keystore
      expect(() async => await keyStore?.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));
      expect(commitLog.getLatestCommitEntry(key2)?.operation, CommitOp.DELETE);
      expect(keyStore?.commitLog?.entriesCount(),
          2);
    });

    tearDown(() async => await tearDownFunc());
  });
}

Future<String?> getKey(keyStore, key) async {
  AtData? atData = await keyStore.get(key);
  return atData?.data;
}

Future<SecondaryKeyStoreManager> getKeystoreManager(
    storageDir, atsign, {required bool optimizeCommits}) async {
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atsign)!;
  var manager = secondaryPersistenceStore.getHivePersistenceManager()!;
  await manager.init(storageDir);
  manager.scheduleKeyExpireTask(null,
      runTimeInterval: Duration(seconds: 10), optimizeCommits: optimizeCommits);
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
