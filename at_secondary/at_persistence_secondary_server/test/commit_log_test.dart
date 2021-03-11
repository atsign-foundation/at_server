import 'dart:convert';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store_factory.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = Directory.current.path + '/test/hive';
  var keyStoreManager;

  group('A group of commit log test', () {
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));
    test('test single insert', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(_getShaForAtsign('@alice'));
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
          .getCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_3 =
          await commitLogInstance.commit('location@alice', CommitOp.DELETE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 2);
      var committedEntry = await commitLogInstance.getEntry(key_2);
      expect(committedEntry.atKey, 'location@alice');
      expect(committedEntry.operation, CommitOp.UPDATE);
    });

    test('test get entry ', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(_getShaForAtsign('@alice'));
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
          .getCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_3 =
          await commitLogInstance.commit('location@alice', CommitOp.DELETE);
      var key_4 = await commitLogInstance.commit('phone@bob', CommitOp.UPDATE);
      var key_5 =
          await commitLogInstance.commit('email@charlie', CommitOp.UPDATE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 4);
      var changes = await commitLogInstance.getChanges(key_2, '');
      expect(changes.length, 3);
      expect(changes[0].atKey, 'location@alice');
      expect(changes[1].atKey, 'phone@bob');
      expect(changes[2].atKey, 'email@charlie');
    });

    test('test last sequence number called once', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
    });

    test('test last sequence number called multiple times', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
      expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
    });

    test('test commit - box not available', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(_getShaForAtsign('@alice'));
      await commitLogInstance.close();
      expect(
          () async =>
              await commitLogInstance.commit('location@alice', CommitOp.UPDATE),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    test('test get entry - box not available', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance.close();
      expect(() async => await commitLogInstance.getEntry(key_1),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    test('test entries since commit Id - box not available', () async {
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(_getShaForAtsign('@alice'));
      var key_1 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      await Hive.close();
      await AtCommitLogManagerImpl.getInstance().close();
      expect(() async => await commitLogInstance.getEntry(key_2),
          throwsA(predicate((e) => e is DataStoreException)));
    });

    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(_getShaForAtsign('@alice'), commitLogPath: storageDir);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice');
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager();
  await persistenceManager.init('@alice', storageDir);
  await persistenceManager.openVault('@alice');
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager.keyStore = hiveKeyStore;
  return keyStoreManager;
}

void tearDownFunc() async {
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    await Directory('test/hive/').deleteSync(recursive: true);
  }
  AtCommitLogManagerImpl.getInstance().clear();
}

String _getShaForAtsign(String atsign) {
  var bytes = utf8.encode(atsign);
  return sha256.convert(bytes).toString();
}
