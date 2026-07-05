import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';

import 'test_utils.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive/';

  group('test scenarios for expired keys - CASE: optimizeCommits set to TRUE',
      () {
    String atsign = '@test_user_1';
    HiveAtKeyValueStore? keyValueStore;
    late HiveAtCommitLog commitLog;

    setUp(() async {
      keyValueStore =
          await getKeystoreManager(storageDir, atsign, optimizeCommits: true);
      assert(keyValueStore != null);
      commitLog = keyValueStore!.commitLog as HiveAtCommitLog;
    });

    test('fetch expired key returns throws exception', () async {
      String key = '123.g1t1$atsign';
      var atData = AtData()..data = 'abc';
      atData.metaData = AtMetaData()..ttl = 5;
      await keyValueStore?.put(key, atData);
      var atDataResponse = await keyValueStore?.get(key);
      assert(atDataResponse!.data == 'abc');
      await keyValueStore!.deleteExpiredKeys();
      expect(
          () async => getKey(keyValueStore, key),
          throwsA(predicate((e) =>
              e.toString().contains('$key does not exist in keystore'))));
    }, timeout: Timeout(Duration(minutes: 1)));

    test('ensure expired keys deletion does NOT add entry to commitLog',
        () async {
      String key = 'no_commit_log_test.g1t2$atsign';
      var atData = AtData()..data = 'randomDataString';
      atData.metaData = AtMetaData()..ttl = 2;
      await keyValueStore?.put(key, atData);
      expect((await keyValueStore?.get(key))?.data, atData.data);

      await keyValueStore?.deleteExpiredKeys();
      await Future.delayed(Duration(seconds: 2));
      // ensure that the key is expired
      expect(
          () async => await keyValueStore!.get(key),
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
      atData.metaData = AtMetaData()..ttl = 2;
      await keyValueStore?.put(key1, atData);

      // insert key2 and manually delete the key
      String key2 = 'no_commit_2.g1t3$atsign';
      atData = AtData()..data = 'randomDataString2';
      await keyValueStore!.put(key2, atData);
      await keyValueStore!.remove(key2);

      await keyValueStore!.deleteExpiredKeys();
      await Future.delayed(Duration(seconds: 2));

      // ensure that key1 and key2 do NOT exist in the keystore
      expect(() async => await keyValueStore!.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));
      expect(() async => await keyValueStore!.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));

      // key1 should NOT have a commitEntry as it was removed by deletedExpiredKeys job
      expect(commitLog.getLatestCommitEntry(key1), null);
      expect(commitLog.getLatestCommitEntry(key2)!.operation, CommitOp.DELETE);

      // 1 commit entry available belongs to the key created and deleted manually
      expect(keyValueStore!.commitLog!.entriesCount(), 1);
    });

    test('validate commit log with keys that are expired and deleted',
        () async {
      // insert key 1 that expires in 10ms
      String key1 = 'expired_key1.g1t4$atsign';
      var atData = AtData()..data = 'randomDataString1';
      atData.metaData = AtMetaData()..ttl = 3;
      await keyValueStore!.put(key1, atData);

      // insert key2 and manually delete the key
      String key2 = 'delete_key1.g1t4$atsign';
      atData = AtData()..data = 'randomDataString2';
      await keyValueStore!.put(key2, atData);
      await keyValueStore!.remove(key2);

      // insert key3 that does NOT expire and NOT deleted
      String key3 = 'normal_key.g1t4$atsign';
      atData = AtData()..data = 'randomDataString3';
      await keyValueStore!.put(key3, atData);

      await keyValueStore!.deleteExpiredKeys();
      await Future.delayed(Duration(seconds: 2));

      // key1 and key should NOT be in the keystore as they have been removed
      expect(() async => await keyValueStore!.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));
      expect(() async => await keyValueStore!.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));

      // validate commitOp's for respective keys
      expect(commitLog.getLatestCommitEntry(key1), null);
      expect(commitLog.getLatestCommitEntry(key2)!.operation, CommitOp.DELETE);
      expect(commitLog.getLatestCommitEntry(key3)!.operation, CommitOp.UPDATE);

      expect(commitLog.getLatestCommitEntry(key2)!.commitId, 2);
      expect(commitLog.getLatestCommitEntry(key3)!.commitId, 3);

      // Expected num of commit entries is 2 - key 2 and key 3 should have commit entries
      expect(keyValueStore!.commitLog!.entriesCount(), 2);
    });

    tearDown(() async => await tearDownFunc());
  });

  group('test scenarios for expired keys - CASE: optimizeCommits set to FALSE',
      () {
    String atsign = '@test_user_2';
    HiveAtKeyValueStore? keyValueStore;
    late HiveAtCommitLog commitLog;

    setUp(() async {
      keyValueStore =
          await getKeystoreManager(storageDir, atsign, optimizeCommits: false);
      assert(keyValueStore != null);
      commitLog = keyValueStore!.commitLog as HiveAtCommitLog;
    });

    test('ensure expired keys deletion entry is added to commitLog', () async {
      String key = 'commit_test.g2t1$atsign';
      var atData = AtData()..data = 'randomDataString';
      atData.metaData = AtMetaData()..ttl = 500;
      await keyValueStore!.put(key, atData);
      // ensure key is inserted
      expect((await keyValueStore!.get(key))!.data, atData.data);

      await Future.delayed(Duration(seconds: 1));
      await keyValueStore!.deleteExpiredKeys();
      // ensure that the key is expired
      expect(
          () async => await keyValueStore!.get(key),
          throwsA(predicate((e) =>
              e.toString().contains('$key does not exist in keystore'))));

      expect(commitLog.getLatestCommitEntry(key)!.operation, CommitOp.DELETE);
      expect(commitLog.entriesCount(), 1);
    });

    test('manually deleted keys add a commitEntry to commitLog', () async {
      // insert key 1 that expires in 100ms
      String key1 = 'no_commit_3.g2t2$atsign';
      var atData = AtData()..data = 'randomDataString1';
      atData.metaData = AtMetaData()..ttl = 100;
      await keyValueStore!.put(key1, atData);
      await Future.delayed(Duration(seconds: 1));
      await keyValueStore!.deleteExpiredKeys();
      // ensure that the key is expired
      expect(() async => await keyValueStore!.get(key1),
          throwsA(predicate((p0) => p0 is KeyNotFoundException)));
      expect(commitLog.getLatestCommitEntry(key1)!.operation, CommitOp.DELETE);

      // insert key2 that is manually deleted
      String key2 = 'no_commit_4.g2t2$atsign';
      atData = AtData()..data = 'randomDataString2';
      await keyValueStore!.put(key2, atData);
      await keyValueStore!.remove(key2);
      // ensure that the second key does not exist in keystore
      expect(() async => await keyValueStore!.get(key2),
          throwsA(predicate((e) => e is KeyNotFoundException)));
      expect(commitLog.getLatestCommitEntry(key2)!.operation, CommitOp.DELETE);

      expect(keyValueStore!.commitLog!.entriesCount(), 2);
    });

    tearDown(() async => await tearDownFunc());
  });
}

Future<String?> getKey(keyValueStore, key) async {
  AtData? atData = await keyValueStore.get(key);
  return atData?.data;
}

Future<HiveAtKeyValueStore> getKeystoreManager(
  storageDir,
  atsign, {
  required bool optimizeCommits,
}) =>
    setUpTestKeyStore(atsign, storageDir: storageDir);

Future<void> tearDownFunc() => tearDownTestPersistence(storageDir: 'test/hive');
