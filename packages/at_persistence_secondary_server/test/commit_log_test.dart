import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';

  group('A group of commit log test', () {
    setUp(() async => await setUpFunc(storageDir));
    test('test single insert', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var hiveKey =
          await commitLogInstance!.commit('location@alice', CommitOp.UPDATE);
      var committedEntry = await (commitLogInstance.getEntry(hiveKey));
      expect(committedEntry?.key, hiveKey);
      expect(committedEntry?.atKey, 'location@alice');
      expect(committedEntry?.operation, CommitOp.UPDATE);
      commitLogInstance = null;
    });
    test('test multiple insert', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      var key_2 =
          await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance?.commit('location@alice', CommitOp.DELETE);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), 2);
      var committedEntry = await (commitLogInstance?.getEntry(key_2));
      expect(committedEntry?.atKey, 'location@alice');
      expect(committedEntry?.operation, CommitOp.UPDATE);
    });

    test('test get entry ', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var key_1 =
          await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      var committedEntry = await (commitLogInstance?.getEntry(key_1));
      expect(committedEntry?.atKey, 'location@alice');
      expect(committedEntry?.operation, CommitOp.UPDATE);
      expect(committedEntry?.opTime, isNotNull);
      expect(committedEntry?.commitId, isNotNull);
    });

    test('test entries since commit Id', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      var key_1 =
          await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance!.commit('phone@alice', CommitOp.UPDATE);
      var changes = await commitLogInstance.getChanges(key_1, '');
      expect(changes.length, 1);
      expect(changes[0].atKey, 'phone@alice');
    });

    test('test last sequence number called once', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), 1);
    });

    test('test last sequence number called multiple times', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), 1);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), 1);
    });

    test(
        'test to verify commitId does not increment for public hidden keys with single _',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var commitId = await commitLogInstance?.commit(
          'public:_location@alice', CommitOp.UPDATE);
      expect(commitId, -1);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), -1);
    });

    test('test to verify commitId does not increment for privatekey', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var commitId = await commitLogInstance?.commit(
          'privatekey:testkey@alice', CommitOp.UPDATE);
      expect(commitId, -1);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), -1);
    });

    test('test to verify commitId does not increment for signing public key',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var commitId = await commitLogInstance?.commit(
          'public:signing_publickey@alice', CommitOp.UPDATE);
      expect(commitId, -1);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), -1);
    }, skip: 'Reverting the changes temporarily. Hence skipping the test');

    test('test to verify commitId does not increment for signing private key',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var commitId = await commitLogInstance?.commit(
          '@alice:signing_privatekey@alice', CommitOp.UPDATE);
      expect(commitId, -1);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), -1);
    }, skip: 'Reverting the changes temporarily. Hence skipping the test');

    test(
        'test to verify commitId does not increment for key starting with private:',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var commitId = await commitLogInstance?.commit(
          'private:testkey@alice', CommitOp.UPDATE);
      expect(commitId, -1);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), -1);
    });

    test(
        'test to verify commitId does increment for public hidden keys with multiple __',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var commitId = await commitLogInstance?.commit(
          'public:__location@alice', CommitOp.UPDATE);
      expect(commitId, 0);
      expect(commitLogInstance?.lastCommittedSequenceNumber(), 0);
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests to verify lastSynced commit entry', () {
    setUp(() async => await setUpFunc(storageDir, enableCommitId: false));
    test(
        'test to verify the last synced entry returns entry with highest commit id',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('mobile@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('phone@alice', CommitOp.UPDATE);

      CommitEntry? commitEntry0 = await commitLogInstance?.getEntry(0);
      await commitLogInstance?.update(commitEntry0!, 1);
      CommitEntry? commitEntry1 = await commitLogInstance?.getEntry(1);
      await commitLogInstance?.update(commitEntry1!, 0);
      var lastSyncedEntry = await commitLogInstance?.lastSyncedEntry();
      expect(lastSyncedEntry!.commitId, 1);
      var lastSyncedCacheSize = commitLogInstance!.commitLogKeyStore
          .getLastSyncedEntryCacheMapValues()
          .length;
      expect(lastSyncedCacheSize, 1);
    });

    test('test to verify the last synced entry with regex', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location.buzz@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('mobile.wavi@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('phone.buzz@alice', CommitOp.UPDATE);

      CommitEntry? commitEntry0 = await commitLogInstance?.getEntry(0);
      await commitLogInstance?.update(commitEntry0!, 2);
      CommitEntry? commitEntry1 = await commitLogInstance?.getEntry(1);
      await commitLogInstance?.update(commitEntry1!, 1);
      CommitEntry? commitEntry2 = await commitLogInstance?.getEntry(2);
      await commitLogInstance?.update(commitEntry2!, 0);
      var lastSyncedEntry =
          await commitLogInstance?.lastSyncedEntryWithRegex('buzz');
      expect(lastSyncedEntry!.atKey!, 'location.buzz@alice');
      expect(lastSyncedEntry.commitId!, 2);
      lastSyncedEntry =
          await commitLogInstance?.lastSyncedEntryWithRegex('wavi');
      expect(lastSyncedEntry!.atKey!, 'mobile.wavi@alice');
      expect(lastSyncedEntry.commitId!, 1);
      var lastSyncedEntriesList = commitLogInstance!.commitLogKeyStore
          .getLastSyncedEntryCacheMapValues();
      expect(lastSyncedEntriesList.length, 2);
    });

    test(
        'Test to verify that null is returned when no values are present in local keystore',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var lastSyncedEntry = await commitLogInstance?.lastSyncedEntry();
      expect(lastSyncedEntry, null);
    });

    test(
        'Test to verify that null is returned when matches entry for regex is not found',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location.buzz@alice', CommitOp.UPDATE);
      CommitEntry? commitEntry0 = await commitLogInstance?.getEntry(0);
      await commitLogInstance?.update(commitEntry0!, 2);
      var lastSyncedEntry =
          await commitLogInstance?.lastSyncedEntryWithRegex('wavi');
      expect(lastSyncedEntry, null);
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of commit log compaction tests', () {
    setUp(() async => await setUpFunc(storageDir));
    test('Test to verify compaction when single is modified ten times',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var compactionService =
          CommitLogCompactionService(commitLogInstance!.commitLogKeyStore);
      commitLogInstance.addEventListener(compactionService);
      for (int i = 0; i <= 50; i++) {
        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
      }

      var list = compactionService.getEntries('location@alice');
      expect(list?.getSize(), 1);
    });

    test('Test to verify compaction when two are modified ten times', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var compactionService =
          CommitLogCompactionService(commitLogInstance!.commitLogKeyStore);
      commitLogInstance.addEventListener(compactionService);
      for (int i = 0; i <= 50; i++) {
        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('country@alice', CommitOp.UPDATE);
      }
      var locationList = compactionService.getEntries('location@alice');
      var countryList = compactionService.getEntries('country@alice');
      expect(locationList!.getSize(), 1);
      expect(countryList!.getSize(), 1);
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests to verify repair commit log', () {
    setUp(() async => await setUpFunc(storageDir, enableCommitId: false));
    test('A test to verify null commit id gets replaced with hive internal key',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      var commitLogMap = await commitLogInstance?.commitLogKeyStore.toMap();
      expect(commitLogMap?.values.first.commitId, null);
      await commitLogInstance?.commitLogKeyStore.repairCommitLog(commitLogMap!);
      commitLogMap = await commitLogInstance?.commitLogKeyStore.toMap();
      expect(commitLogMap?.values.first.commitId, 0);
    });

    test(
        'A test to verify multiple null commit id gets replaced with hive internal key',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      // Inserting commitEntry with commitId 0
      await commitLogInstance!.commitLogKeyStore.getBox().add(
          CommitEntry('location@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 0);
      // Inserting commitEntry with null commitId
      await commitLogInstance.commitLogKeyStore
          .getBox()
          .add(CommitEntry('location@alice', CommitOp.UPDATE, DateTime.now()));
      // Inserting commitEntry with commitId 2
      await commitLogInstance.commitLogKeyStore.getBox().add(
          CommitEntry('phone@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 2);
      // Inserting commitEntry with null commitId
      await commitLogInstance.commitLogKeyStore
          .getBox()
          .add(CommitEntry('mobile@alice', CommitOp.UPDATE, DateTime.now()));

      var commitLogMap = await commitLogInstance.commitLogKeyStore.toMap();
      await commitLogInstance.commitLogKeyStore.repairCommitLog(commitLogMap);
      commitLogMap = await commitLogInstance.commitLogKeyStore.toMap();
      commitLogMap.forEach((key, value) {
        assert(value.commitId != null);
        expect(value.commitId, key);
      });

      // verify the commit id's return correct key's
      expect((await commitLogInstance.commitLogKeyStore.get(1))?.atKey,
          'location@alice');
      expect((await commitLogInstance.commitLogKeyStore.get(3))?.atKey,
          'mobile@alice');
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests to verify commit log cache map', () {
    setUp(() async => await setUpFunc(storageDir, enableCommitId: true));
    test('test to verify the entries count in commit cache map after commit',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('mobile@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('phone@alice', CommitOp.UPDATE);

      Iterator? entriesIterator = commitLogInstance?.getEntries(-1);
      int commitLogCountBeforeDeletion = 0;
      if (entriesIterator != null) {
        while (entriesIterator.moveNext()) {
          commitLogCountBeforeDeletion++;
        }
      }
      expect(commitLogCountBeforeDeletion, 3);
    });
    test(
        'test to verify the entries count in commit cache map after removing from commit log',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      int? commitIdToRemove =
          await commitLogInstance?.commit('mobile@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('phone@alice', CommitOp.UPDATE);

      Iterator? entriesIterator = commitLogInstance?.getEntries(-1);
      int commitLogCountBeforeDeletion = 0;
      if (entriesIterator != null) {
        while (entriesIterator.moveNext()) {
          commitLogCountBeforeDeletion++;
        }
      }
      expect(commitLogCountBeforeDeletion, 3);
      await commitLogInstance?.commitLogKeyStore.remove(commitIdToRemove!);
      entriesIterator = commitLogInstance?.getEntries(-1);
      int commitLogCountAfterDeletion = 0;
      if (entriesIterator != null) {
        while (entriesIterator.moveNext()) {
          commitLogCountAfterDeletion++;
        }
      }
      expect(commitLogCountAfterDeletion, 2);
    });
    test('test to verify the whether correct entry is removed from cache',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      await commitLogInstance?.commit('location@alice', CommitOp.UPDATE);
      int? commitIdToRemove =
          await commitLogInstance?.commit('mobile@alice', CommitOp.UPDATE);
      await commitLogInstance?.commit('phone@alice', CommitOp.UPDATE);

      await commitLogInstance?.commitLogKeyStore.remove(commitIdToRemove!);
      final commitEntry = await commitLogInstance?.getEntry(commitIdToRemove);
      expect(commitEntry, isNull);
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests to verify local key does not add to commit log', () {
    test('local key does not add to commit log', () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      var commitId = await commitLogInstance?.commit(
          'local:phone.wavi@alice', CommitOp.UPDATE);
      expect(commitId, -1);
    });

    test(
        'Test to verify local created with static local method does not add to commit log',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));

      var atKey = AtKey.local('phone', '@alice', namespace: 'wavi').build();

      var commitId =
          await commitLogInstance?.commit(atKey.toString(), CommitOp.UPDATE);
      expect(commitId, -1);
    });

    test('Test to verify local created with AtKey does not add to commit log',
        () async {
      var commitLogInstance =
          await (AtCommitLogManagerImpl.getInstance().getCommitLog('@alice'));
      var atKey = AtKey()
        ..key = 'phone'
        ..sharedBy = '@alice'
        ..namespace = 'wavi'
        ..isLocal = true;
      var commitId =
          await commitLogInstance?.commit(atKey.toString(), CommitOp.UPDATE);
      expect(commitId, -1);
    });
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir,
    {bool enableCommitId = true}) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice',
          commitLogPath: storageDir, enableCommitId: enableCommitId);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice')!;
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
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
