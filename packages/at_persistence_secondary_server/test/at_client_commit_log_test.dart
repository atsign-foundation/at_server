import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/client/at_client_commit_log_keystore.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';

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
      var lastSyncedCacheSize =
          (commitLogInstance!.commitLogKeyStore as AtClientCommitLogKeyStore)
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
      var lastSyncedEntriesList =
          (commitLogInstance!.commitLogKeyStore as AtClientCommitLogKeyStore)
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
