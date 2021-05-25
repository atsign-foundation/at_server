import 'dart:convert';
import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store_factory.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = Directory.current.path + '/test/commit';

  group('A group of commit log test', () {
    setUp(() async => await setUpFunc(storageDir));
    test('test single insert', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      var hiveKey =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var committedEntry = await commitLogInstance.getEntry(hiveKey);
      expect(committedEntry.key, hiveKey);
      expect(committedEntry.atKey, 'location@alice');
      expect(committedEntry.operation, CommitOp.UPDATE);
      commitLogInstance = null;
    });
    test('test multiple insert', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance.commit('location@alice', CommitOp.DELETE);
      expect(await commitLogInstance.lastCommittedSequenceNumber(), 2);
      var committedEntry = await commitLogInstance.getEntry(key_2);
      expect(committedEntry.atKey, 'location@alice');
      expect(committedEntry.operation, CommitOp.UPDATE);
    });

    test('test get entry ', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var committedEntry = await commitLogInstance.getEntry(key_1);
      expect(committedEntry.atKey, 'location@alice');
      expect(committedEntry.operation, CommitOp.UPDATE);
      expect(committedEntry.opTime, isNotNull);
      expect(committedEntry.commitId, isNotNull);
    });

    test('test entries since commit Id', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance.commit('location@alice', CommitOp.DELETE);
      await commitLogInstance.commit('phone@bob', CommitOp.UPDATE);
      await commitLogInstance.commit('email@charlie', CommitOp.UPDATE);
      expect(await commitLogInstance.lastCommittedSequenceNumber(), 4);
      var changes = await commitLogInstance.getChanges(key_2, '');
      expect(changes.length, 3);
      expect(changes[0].atKey, 'location@alice');
      expect(changes[1].atKey, 'phone@bob');
      expect(changes[2].atKey, 'email@charlie');
    });

    test('test last sequence number called once', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      expect(await commitLogInstance.lastCommittedSequenceNumber(), 1);
    });

    test('test last sequence number called multiple times', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      expect(await commitLogInstance.lastCommittedSequenceNumber(), 1);
      expect(await commitLogInstance.lastCommittedSequenceNumber(), 1);
    });

    test('test commit - box not available', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      await commitLogInstance.close();
      expect(
          () async =>
              await commitLogInstance.commit('location@alice', CommitOp.UPDATE),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    test('test get entry - box not available', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance.close();
      expect(() async => await commitLogInstance.getEntry(key_1),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    test('test entries since commit Id - box not available', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getHiveCommitLog(_getShaForAtsign('@alice'));
      await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await AtCommitLogManagerImpl.getInstance().close();
      expect(() async => await commitLogInstance.getEntry(key_2),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    tearDown(() async => await tearDownFunc());
  });

  group('A group of commit log compaction tests', () {
    test('A test to verify index of duplicate entries are returned', () {
      var commitLogKeystore = CommitLogKeyStore('@alice');
      var commitLogMap = {
        0: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:phone@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":0}')),
        1: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:phone@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":1}')),
        2: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:phone@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":2}'))
      };
      var duplicateIndexList =
          commitLogKeystore.getDuplicateEntries(commitLogMap);
      assert(duplicateIndexList.length == 2);
      assert(duplicateIndexList[0] == 1 && duplicateIndexList[1] == 0);
    });

    test('A test to verify index of all entries are returned', () {
      var commitLogKeystore = CommitLogKeyStore('@alice');
      var commitLogMap = {
        0: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:phone@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":0}')),
        1: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:mobile@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":1}')),
        2: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:location@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":2}'))
      };
      var duplicateIndexList =
          commitLogKeystore.getDuplicateEntries(commitLogMap);
      assert(duplicateIndexList.isEmpty);
    });

    test('A test to verify one of the entries is duplicate', () {
      var commitLogKeystore = CommitLogKeyStore('@alice');
      var commitLogMap = {
        0: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:phone@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":0}')),
        1: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:mobile@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":1}')),
        2: CommitEntry.fromJson(jsonDecode(
            '{\"atKey\":\"@alice:phone@bob\",\"operation\":\"CommitOp.UPDATE\",\"opTime\":\"2021-05-20 03:50:42.109205Z\",\"commitId\":2}'))
      };
      var duplicateIndexList =
          commitLogKeystore.getDuplicateEntries(commitLogMap);
      assert(duplicateIndexList.length == 1);
      assert(duplicateIndexList[0] == 0);
    });
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getHiveCommitLog(_getShaForAtsign('@alice'), commitLogPath: storageDir);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice');
  var persistenceManager = secondaryPersistenceStore.getPersistenceManager();
  await persistenceManager.init('@alice', storageDir);
  var keyStore;
  if (persistenceManager is HivePersistenceManager) {
    await persistenceManager.openVault('@alice');
  }
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  keyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  keyStore.commitLog = commitLogInstance;
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager.keyStore = keyStore;
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory('test/commit/').exists();
  if (isExists) {
    Directory('test/commit/').deleteSync(recursive: true);
  }
}

String _getShaForAtsign(String atsign) {
  var bytes = utf8.encode(atsign);
  return sha256.convert(bytes).toString();
}
