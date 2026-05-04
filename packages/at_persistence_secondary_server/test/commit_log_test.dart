import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_log_keystore.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:hive/hive.dart';

import 'test_utils.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  AtSignLogger.root_level = 'finer';

  group('A group of tests on client commit log', () {
    setUp(() async => await setUpFunc(storageDir, enableCommitId: false));
    group(
        'A group of tests to verify correct commit entries are returned for a given sequence number',
        () {
      test(
          'A test to verify getEntry returns CommitEntry for a given sequence number',
          () async {
        HiveAtCommitLog? commitLogInstance = (await testCommitLogFor('@alice'));
        var hiveKey =
            await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        var committedEntry = await (commitLogInstance.getEntry(hiveKey));
        expect(committedEntry?.key, hiveKey);
        expect(committedEntry?.atKey, 'location@alice');
        expect(committedEntry?.operation, CommitOp.UPDATE);
        expect(committedEntry?.commitId, isNull);
        commitLogInstance = null;
      });

      test('A test to verify getChanges the entries from a given sequence',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        var key_1 =
            await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('phone@alice', CommitOp.UPDATE);

        var changes = await commitLogInstance.getChanges(key_1, '');
        expect(changes.length, 1);
        expect(changes[0].atKey, 'phone@alice');
      });
    });

    group('A group of tests to verify lastSynced commit entry', () {
      setUp(() async => await setUpFunc(storageDir, enableCommitId: false));
      test(
          'test to verify the last synced entry returns entry with highest commit id',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('mobile@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('phone@alice', CommitOp.UPDATE);

        CommitEntry? commitEntry0 = await commitLogInstance.getEntry(0);
        await commitLogInstance.update(commitEntry0!, 1);
        CommitEntry? commitEntry1 = await commitLogInstance.getEntry(1);
        await commitLogInstance.update(commitEntry1!, 0);
        var lastSyncedEntry = await commitLogInstance.lastSyncedEntry();
        expect(lastSyncedEntry!.commitId, 1);
        ClientCommitLogKeyStore keyStore =
            commitLogInstance.commitLogKeyStore as ClientCommitLogKeyStore;
        var lastSyncedCacheSize =
            keyStore.getLastSyncedEntryCacheMapValues().length;
        expect(lastSyncedCacheSize, 1);
      });

      test('test to verify the last synced entry with regex', () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location.buzz@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('mobile.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('phone.buzz@alice', CommitOp.UPDATE);

        CommitEntry? commitEntry0 = await commitLogInstance.getEntry(0);
        await commitLogInstance.update(commitEntry0!, 2);
        CommitEntry? commitEntry1 = await commitLogInstance.getEntry(1);
        await commitLogInstance.update(commitEntry1!, 1);
        CommitEntry? commitEntry2 = await commitLogInstance.getEntry(2);
        await commitLogInstance.update(commitEntry2!, 0);
        var lastSyncedEntry =
            await commitLogInstance.lastSyncedEntryWithRegex('buzz');
        expect(lastSyncedEntry!.atKey!, 'location.buzz@alice');
        expect(lastSyncedEntry.commitId!, 2);
        lastSyncedEntry =
            await commitLogInstance.lastSyncedEntryWithRegex('wavi');
        expect(lastSyncedEntry!.atKey!, 'mobile.wavi@alice');
        expect(lastSyncedEntry.commitId!, 1);
        ClientCommitLogKeyStore keyStore =
            commitLogInstance.commitLogKeyStore as ClientCommitLogKeyStore;
        var lastSyncedEntriesList = keyStore.getLastSyncedEntryCacheMapValues();
        expect(lastSyncedEntriesList.length, 2);
      });

      test(
          'Test to verify that null is returned when no values are present in local keystore',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var lastSyncedEntry = await commitLogInstance.lastSyncedEntry();
        expect(lastSyncedEntry, null);
      });

      test(
          'Test to verify that null is returned when matches entry for regex is not found',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location.buzz@alice', CommitOp.UPDATE);
        CommitEntry? commitEntry0 = await commitLogInstance.getEntry(0);
        await commitLogInstance.update(commitEntry0!, 2);
        var lastSyncedEntry =
            await commitLogInstance.lastSyncedEntryWithRegex('wavi');
        expect(lastSyncedEntry, null);
      });
    });
    group('A group of tests related to fetching uncommitted entries', () {
      test(
          'A test to verify only commit entries with null commitId are returned when enableCommitId is false',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitLogKeystore = commitLogInstance.commitLogKeyStore;
        //setting enable commitId to false - to test client side functionality
        //commitLogKeystore.enableCommitId = false;
        //loop to create 10 keys - even keys have commitId null - odd keys have commitId
        for (int i = 0; i < 10; i++) {
          if (i % 2 == 0) {
            await commitLogKeystore.add(CommitEntry(
                'test_key_false_$i.wavi@alice',
                CommitOp.UPDATE,
                DateTime.now()));
          } else {
            await commitLogKeystore.add(CommitEntry(
                'test_key_false_$i.wavi@alice', CommitOp.UPDATE, DateTime.now())
              ..commitId = i);
          }
        }
        List<CommitEntry> changes =
            await commitLogInstance.commitLogKeyStore.getChanges(-1);
        //run loop and test all commit entries returned have commitId == null
        for (var element in changes) {
          expect(element.commitId, null);
        }
      });
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests on server commit log', () {
    group('A group of commit log test', () {
      setUp(() async => await setUpFunc(storageDir, enableCommitId: true));
      test('test multiple insert', () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('location@alice', CommitOp.DELETE);
        expect(commitLogInstance.lastCommittedSequenceNumber(), 2);
      });

      test('test last sequence number called once', () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
      });

      test('test last sequence number called multiple times', () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
        expect(commitLogInstance.lastCommittedSequenceNumber(), 1);
      });

      test(
          'test to verify commitId does not increment for public hidden keys with single _',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitId = await commitLogInstance.commit(
            'public:_location@alice', CommitOp.UPDATE);
        expect(commitId, -1);
        expect(commitLogInstance.lastCommittedSequenceNumber(), -1);
      });

      test('test to verify commitId does not increment for privatekey',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitId = await commitLogInstance.commit(
            'privatekey:testkey@alice', CommitOp.UPDATE);
        expect(commitId, -1);
        expect(commitLogInstance.lastCommittedSequenceNumber(), -1);
      });

      test('test to verify commitId increments for signing public key',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitId = await commitLogInstance.commit(
            'public:signing_publickey@alice', CommitOp.UPDATE);
        expect(commitId, 0);
        expect(commitLogInstance.lastCommittedSequenceNumber(), 0);
      });

      test('test to verify commitId increments for signing private key',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitId = await commitLogInstance.commit(
            '@alice:signing_privatekey@alice', CommitOp.UPDATE);
        expect(commitId, 0);
        expect(commitLogInstance.lastCommittedSequenceNumber(), 0);
      });

      test(
          'test to verify commitId does not increment for key starting with private:',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitId = await commitLogInstance.commit(
            'private:testkey@alice', CommitOp.UPDATE);
        expect(commitId, -1);
        expect(commitLogInstance.lastCommittedSequenceNumber(), -1);
      });

      test(
          'test to verify commitId does increment for public hidden keys with multiple __',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitId = await commitLogInstance.commit(
            'public:__location@alice', CommitOp.UPDATE);
        expect(commitId, 0);
        expect(commitLogInstance.lastCommittedSequenceNumber(), 0);
      });
      test('test to verify last committed sequenceNumber with regex', () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        await commitLogInstance.commit(
            'public:location_1.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            'public:phone.buzz@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            'public:location_2.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            'public:email.buzz@alice', CommitOp.UPDATE);
        expect(
            await commitLogInstance
                .lastCommittedSequenceNumberWithRegex('buzz'),
            3);
        expect(
            await commitLogInstance
                .lastCommittedSequenceNumberWithRegex('wavi'),
            2);
        await commitLogInstance.commit(
            'public:location_1.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            'public:location_2.wavi@alice', CommitOp.DELETE);
        await commitLogInstance.commit(
            'public:phone.buzz@alice', CommitOp.DELETE);
        await commitLogInstance.commit(
            'public:email.buzz@alice', CommitOp.DELETE);
        expect(
            await commitLogInstance
                .lastCommittedSequenceNumberWithRegex('buzz'),
            7);
        expect(
            await commitLogInstance
                .lastCommittedSequenceNumberWithRegex('wavi'),
            5);
      });
      test(
          'A test to verify lastCommittedSequenceNumber does not  include key which does not match regex',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitLogKeystore = commitLogInstance.commitLogKeyStore;
        await commitLogKeystore.add(CommitEntry(
            'public:phone.buzz@alice', CommitOp.UPDATE, DateTime.now()));
        await commitLogKeystore.add(CommitEntry(
            'public:email.wavi@alice', CommitOp.UPDATE, DateTime.now()));
        final lastCommittedSeq = await commitLogKeystore
            .lastCommittedSequenceNumberWithRegex('.buzz');
        expect(lastCommittedSeq, 0);
      });
      test(
          'A test to verify lastCommittedSequenceNumber include key which matches regex and enrollednamespace',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitLogKeystore = commitLogInstance.commitLogKeyStore;
        await commitLogKeystore.add(
            CommitEntry('phone.buzz@alice', CommitOp.UPDATE, DateTime.now()));
        await commitLogKeystore.add(
            CommitEntry('phone.wavi@alice', CommitOp.UPDATE, DateTime.now()));
        await commitLogKeystore.add(CommitEntry(
            'location.buzz@alice', CommitOp.UPDATE, DateTime.now()));
        final lastCommittedSeq = await commitLogKeystore
            .lastCommittedSequenceNumberWithRegex('.buzz',
                enrolledNamespace: ['buzz']);
        expect(lastCommittedSeq, 2);
      });
      test(
          'A test to verify lastCommittedSequenceNumber does not include key which does not match enrollednamespace',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitLogKeystore = commitLogInstance.commitLogKeyStore;
        await commitLogKeystore.add(
            CommitEntry('phone.buzz@alice', CommitOp.UPDATE, DateTime.now()));
        await commitLogKeystore.add(
            CommitEntry('phone.wavi@alice', CommitOp.UPDATE, DateTime.now()));
        final lastCommittedSeq = await commitLogKeystore
            .lastCommittedSequenceNumberWithRegex('.*',
                enrolledNamespace: ['buzz']);
        expect(lastCommittedSeq, 0);
      });
    });
    group('A group of tests verifying the one-entry-per-atKey invariant', () {
      setUp(() async => await setUpFunc(storageDir));
      test('Box has exactly 1 entry after 51 commits to the same atKey',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        for (int i = 0; i <= 50; i++) {
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        }
        expect(commitLogInstance.commitLogKeyStore.getEntriesCount(), 1);
      });

      test('Box has exactly 2 entries after 51 commits to two distinct atKeys',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        for (int i = 0; i <= 50; i++) {
          await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
          await commitLogInstance.commit('country@alice', CommitOp.UPDATE);
        }
        expect(commitLogInstance.commitLogKeyStore.getEntriesCount(), 2);
      });

      test('dedupBoxToOnePerAtKey removes legacy duplicates on init', () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        // Simulate legacy data: write entries directly to the box, bypassing
        // the inline-dedup path of add(), so duplicates accumulate.
        final box = commitLogInstance.commitLogKeyStore.getBox();
        for (int i = 0; i < 5; i++) {
          final entry = CommitEntry(
              'legacy@alice', CommitOp.UPDATE, DateTime.now().toUtc());
          final key = await box.add(entry);
          entry.commitId = key;
          await box.put(key, entry);
        }
        expect(commitLogInstance.commitLogKeyStore.getEntriesCount(), 5);
        // Repair triggers dedupBoxToOnePerAtKey.
        await commitLogInstance.commitLogKeyStore
            .repairCommitLogAndCreateCachedMap();
        expect(commitLogInstance.commitLogKeyStore.getEntriesCount(), 1);
      });

      test('A test to verify old commit entry is removed when a key is updated',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        for (int i = 0; i < 5; i++) {
          await commitLogInstance.commit(
              'location.wavi@alice', CommitOp.UPDATE);
        }
        final entry = await commitLogInstance
            .iterate(
                where: (e) => RegExp('location.wavi').hasMatch(e.atKey ?? ''))
            .first;
        expect(entry.commitId, 4);
        expect(entry.atKey, 'location.wavi@alice');
        expect(entry.operation, CommitOp.UPDATE);
      });

      test('A test to verify old commit entry is removed when a key is delete',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        await commitLogInstance.commit('location.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('location.wavi@alice', CommitOp.DELETE);
        // Fetch the commit entry
        final entry = await commitLogInstance
            .iterate(
                where: (e) => RegExp('location.wavi').hasMatch(e.atKey ?? ''))
            .first;
        expect(entry.commitId, 1);
        expect(entry.atKey, 'location.wavi@alice');
        expect(entry.operation, CommitOp.DELETE);
      });

      test(
          'A test to verify if size of commit log matches length of commit log cache map then commit log keystore is compacted',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        // Add 5 distinct keys
        await commitLogInstance.commit('firstname.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('lastName.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('country.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('phone.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('location.wavi@alice', CommitOp.UPDATE);
        // Update the keys
        await commitLogInstance.commit(
            'location.wavi@alice', CommitOp.UPDATE_ALL);
        await commitLogInstance.commit(
            'lastName.wavi@alice', CommitOp.UPDATE_ALL);
        await commitLogInstance.commit('firstname.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('country.wavi@alice', CommitOp.UPDATE);
        // Add a new key which is NOT in commit log keystore
        await commitLogInstance.commit('city.wavi@alice', CommitOp.UPDATE);
        // Delete the existing key
        await commitLogInstance.commit('location.wavi@alice', CommitOp.DELETE);
        // Verify size of commit log keystore and commit log cache map are equal
        expect(commitLogInstance.commitLogKeyStore.getBox().keys.length,
            commitLogInstance.commitLogKeyStore.commitEntriesList().length);
        // Get all entries from the commit log keystore.
        Iterator itr =
            commitLogInstance.commitLogKeyStore.getBox().keys.iterator;
        itr.moveNext();
        CommitEntry commitEntry =
            (commitLogInstance.commitLogKeyStore.getBox() as Box)
                .get(itr.current);
        expect(commitEntry.atKey, 'phone.wavi@alice');
        expect(commitEntry.commitId, 3);
        expect(commitEntry.operation, CommitOp.UPDATE);
        itr.moveNext();
        commitEntry = (commitLogInstance.commitLogKeyStore.getBox() as Box)
            .get(itr.current);
        expect(commitEntry.atKey, 'lastName.wavi@alice');
        expect(commitEntry.commitId, 6);
        expect(commitEntry.operation, CommitOp.UPDATE_ALL);
        itr.moveNext();
        commitEntry = (commitLogInstance.commitLogKeyStore.getBox() as Box)
            .get(itr.current);
        expect(commitEntry.atKey, 'firstname.wavi@alice');
        expect(commitEntry.commitId, 7);
        expect(commitEntry.operation, CommitOp.UPDATE);
        itr.moveNext();
        commitEntry = (commitLogInstance.commitLogKeyStore.getBox() as Box)
            .get(itr.current);
        expect(commitEntry.atKey, 'country.wavi@alice');
        expect(commitEntry.commitId, 8);
        expect(commitEntry.operation, CommitOp.UPDATE);
        itr.moveNext();
        commitEntry = (commitLogInstance.commitLogKeyStore.getBox() as Box)
            .get(itr.current);
        expect(commitEntry.atKey, 'city.wavi@alice');
        expect(commitEntry.commitId, 9);
        expect(commitEntry.operation, CommitOp.UPDATE);
        itr.moveNext();
        commitEntry = (commitLogInstance.commitLogKeyStore.getBox() as Box)
            .get(itr.current);
        expect(commitEntry.atKey, 'location.wavi@alice');
        expect(commitEntry.commitId, 10);
        expect(commitEntry.operation, CommitOp.DELETE);
        // To ensure there are no more keys in iterator.
        expect(itr.moveNext(), false);
      });
    });

    group('A group of tests to verify repair commit log', () {
      // When client syncs data to server, there might be chance of partial execution of
      // add method (due to application crash)- leading to null commitIds being added into
      // the server commit entry. Hence setting the "enableCommitId" to false to inject
      // commit entries with null commit ids.
      setUp(() async => await setUpFunc(storageDir, enableCommitId: false));
      test(
          'A test to verify null commit id gets replaced with hive internal key',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        var commitLogMap = await commitLogInstance.commitLogKeyStore.toMap();
        expect(commitLogMap.values.first.commitId, null);
        await commitLogInstance.commitLogKeyStore
            .repairNullCommitIDs(commitLogMap);
        commitLogMap = await commitLogInstance.commitLogKeyStore.toMap();
        expect(commitLogMap.values.first.commitId, 0);
      });

      test(
          'A test to verify multiple null commit id gets replaced with hive internal key',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        // Inserting commitEntry with commitId 0
        await commitLogInstance.commitLogKeyStore.add(
            CommitEntry('location@alice', CommitOp.UPDATE, DateTime.now())
              ..commitId = 0);
        // Inserting commitEntry with null commitId
        await commitLogInstance.commitLogKeyStore.add(
            CommitEntry('location@alice', CommitOp.UPDATE, DateTime.now()));
        // Inserting commitEntry with commitId 2
        await commitLogInstance.commitLogKeyStore.add(
            CommitEntry('phone@alice', CommitOp.UPDATE, DateTime.now())
              ..commitId = 2);
        // Inserting commitEntry with null commitId
        await commitLogInstance.commitLogKeyStore
            .add(CommitEntry('mobile@alice', CommitOp.UPDATE, DateTime.now()));

        var commitLogMap = await commitLogInstance.commitLogKeyStore.toMap();
        await commitLogInstance.commitLogKeyStore
            .repairNullCommitIDs(commitLogMap);
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
    });
    group('A group of tests to verify local key does not add to commit log',
        () {
      setUp(() async => await setUpFunc(storageDir, enableCommitId: true));
      test('local key does not add to commit log', () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        var commitId = await commitLogInstance.commit(
            'local:phone.wavi@alice', CommitOp.UPDATE);
        expect(commitId, -1);
      });

      test(
          'Test to verify local created with static local method does not add to commit log',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        var atKey = AtKey.local('phone', '@alice', namespace: 'wavi').build();

        var commitId =
            await commitLogInstance.commit(atKey.toString(), CommitOp.UPDATE);
        expect(commitId, -1);
      });

      test('Test to verify local created with AtKey does not add to commit log',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var atKey = AtKey()
          ..key = 'phone'
          ..sharedBy = '@alice'
          ..namespace = 'wavi'
          ..isLocal = true;
        var commitId =
            await commitLogInstance.commit(atKey.toString(), CommitOp.UPDATE);
        expect(commitId, -1);
      });
    });
    group('A group of tests to verify commit log cache map', () {
      setUp(() async => await setUpFunc(storageDir, enableCommitId: true));
      test('test to verify the entries count in commit cache map after commit',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('mobile@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('phone@alice', CommitOp.UPDATE);

        final entriesList = await commitLogInstance.iterate().toList();
        expect(entriesList.length, 3);
      });
      test(
          'A test to verify entries in commit cache map are sorted by commit-id in ascending order',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        await commitLogInstance.commit(
            '@alice:key1.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            '@alice:key2.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            '@alice:key3.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            '@alice:key2.wavi@alice', CommitOp.DELETE);
        await commitLogInstance.commit(
            '@alice:key1.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commitLogKeyStore
            .repairCommitLogAndCreateCachedMap();
        final entries = await commitLogInstance.iterate().toList();
        expect(entries.length, 3);
        expect(entries[0].atKey, '@alice:key3.wavi@alice');
        expect(entries[0].commitId, 2);
        expect(entries[0].operation, CommitOp.UPDATE);

        expect(entries[1].atKey, '@alice:key2.wavi@alice');
        expect(entries[1].commitId, 3);
        expect(entries[1].operation, CommitOp.DELETE);

        expect(entries[2].atKey, '@alice:key1.wavi@alice');
        expect(entries[2].commitId, 4);
        expect(entries[2].operation, CommitOp.UPDATE);
      });

      test(
          'A test to verify the order of keys and values in commit log cache map',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        await commitLogInstance.commit(
            '@alice:key1.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            '@alice:key2.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            '@alice:key3.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commit(
            '@alice:key2.wavi@alice', CommitOp.DELETE);
        await commitLogInstance.commit(
            '@alice:key1.wavi@alice', CommitOp.UPDATE);
        await commitLogInstance.commitLogKeyStore
            .repairCommitLogAndCreateCachedMap();

        List<MapEntry<String, CommitEntry>> commitEntriesList =
            commitLogInstance.commitLogKeyStore.commitEntriesList();
        expect(commitEntriesList[0].key, '@alice:key3.wavi@alice');
        expect(commitEntriesList[0].value.commitId, 2);

        expect(commitEntriesList[1].key, '@alice:key2.wavi@alice');
        expect(commitEntriesList[1].value.commitId, 3);

        expect(commitEntriesList[2].key, '@alice:key1.wavi@alice');
        expect(commitEntriesList[2].value.commitId, 4);
      });

      test(
          'A test to verify the entries count in commit cache map after removing from commit log',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        int? commitIdToRemove =
            await commitLogInstance.commit('mobile@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('phone@alice', CommitOp.UPDATE);

        var entriesList = await commitLogInstance.iterate().toList();
        expect(entriesList.length, 3);
        await commitLogInstance.commitLogKeyStore.remove(commitIdToRemove!);
        entriesList = await commitLogInstance.iterate().toList();
        expect(entriesList.length, 2);
      });

      test('A test to verify the whether correct entry is removed from cache',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));

        await commitLogInstance.commit('location@alice', CommitOp.UPDATE);
        int? commitIdToRemove =
            await commitLogInstance.commit('mobile@alice', CommitOp.UPDATE);
        await commitLogInstance.commit('phone@alice', CommitOp.UPDATE);

        await commitLogInstance.commitLogKeyStore.remove(commitIdToRemove!);
        final entries = await commitLogInstance.iterate().toList();
        expect(entries.length, 2);
        expect(entries[0].atKey, 'location@alice');
        expect(entries[1].atKey, 'phone@alice');
      });

      test(
          'A test to verify all commit entries are returned when enableCommitId is true',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        var commitLogKeystore = commitLogInstance.commitLogKeyStore;
        //loop to create 10 keys - even keys have commitId null - odd keys have commitId
        for (int i = 0; i < 10; i++) {
          if (i % 2 == 0) {
            await commitLogKeystore.add(CommitEntry(
                'test_key_true_$i@alice', CommitOp.UPDATE, DateTime.now()));
          } else {
            await commitLogKeystore.add(CommitEntry(
                'test_key_true_$i@alice', CommitOp.UPDATE, DateTime.now())
              ..commitId = i);
          }
        }
        // run loop to ensure all commit entries have been returned;
        // irrespective of commitId null or not
        int i = 0;
        await for (final entry in commitLogInstance.iterate()) {
          expect(entry.commitId, i);
          i++;
        }
        expect(i, 10);
      });
      test(
          'verify that CommitEntry with higher commitId is retained in cache for the same key',
          () async {
        var commitLogInstance = (await testCommitLogFor('@alice'));
        String key = 'same_key.test@alice';
        int? firstCommitId =
            await commitLogInstance.commit(key, CommitOp.UPDATE);
        Future<int?>? secondCommitIdFuture = // no await here is intentional
            commitLogInstance.commit(key, CommitOp.UPDATE);
        int? thirdCommitId =
            await commitLogInstance.commit(key, CommitOp.UPDATE);

        CommitEntry? commitEntryInCache =
            commitLogInstance.getLatestCommitEntry(key);
        // This is to create an un-orderly update of commitEntries
        int? secondCommitId = await secondCommitIdFuture;
        assert(
            thirdCommitId! > firstCommitId! && thirdCommitId > secondCommitId!);
        expect(commitEntryInCache?.commitId, thirdCommitId);
      });
      // Tests for regex/alwaysIncludeInSync and skipDeletesUntil semantics
      // were retired alongside getEntries (Phase 3.5f). Those behaviours
      // now live in SyncProgressiveVerbHandler's iterate(where:) closure
      // and are exercised by tests in sync_verb_test.dart and the
      // functional suite.
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests to verify commit log instances', () {
    test(
        'A test to verify CommitLogKeyStore is set when enableCommitId is set to true',
        () async {
      await setUpFunc(storageDir, enableCommitId: true);
      HiveAtCommitLog? atCommitLog = (await testCommitLogFor('@alice'));
      expect(atCommitLog.commitLogKeyStore, isA<CommitLogKeyStore>());
    });

    test(
        'A test to verify ClientCommitLogKeyStore is set when enableCommitId is set to false',
        () async {
      await setUpFunc(storageDir, enableCommitId: false);
      HiveAtCommitLog? atCommitLog = (await testCommitLogFor('@alice'));
      expect(atCommitLog.commitLogKeyStore, isA<ClientCommitLogKeyStore>());
    });
    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir,
    {bool enableCommitId = true}) async {
  var commitLogInstance = await testCommitLogFor('@alice',
      commitLogPath: storageDir, enableCommitId: enableCommitId);
  var secondaryPersistenceStore = testPersistenceStoreFor('@alice');
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
  await closeTestCommitLogs();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
