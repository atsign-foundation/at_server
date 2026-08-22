import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// The commit-log primitives behind the protocol's `:nc` (no-commit) flag and
/// `:dAt`/`:uAt` operation times:
///
///   * every write path with `skipCommit: true` (put / create / putMeta /
///     remove / removeMany) writes no commit entry AND purges the key's
///     existing entry — [AtCommitLog.removeEntryFor];
///   * `commit(..., opTime:)` records a caller-asserted operation time on the
///     entry, threaded from `remove(deletedAt:)` and from an asserted
///     `updatedAt` on the update paths.
///
/// Runs identically against both backends, except where a pinned divergence
/// says otherwise.
void main() {
  for (final backend in ['hive', 'sqlite']) {
    group('$backend skipCommit purge + opTime', () {
      late Directory tempDir;
      late AtPersistenceFactory factory;
      late AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
      late AtCommitLog commitLog;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('nc_primitives_');
        final AtPersistenceBundle bundle;
        if (backend == 'hive') {
          factory = HiveAtPersistenceFactory();
          bundle = await factory.initialize(
            '@alice',
            HivePersistenceConfig.serverDefaults(
              storagePath: '${tempDir.path}/hive',
              commitLogPath: '${tempDir.path}/commitLog',
              accessLogPath: '${tempDir.path}/accessLog',
              notificationStoragePath: '${tempDir.path}/notification',
            ),
          );
        } else {
          factory = SqliteAtPersistenceFactory();
          bundle = await factory.initialize(
            '@alice',
            SqlitePersistenceConfig.serverDefaults(
                storagePath: '${tempDir.path}/sqlite'),
          );
        }
        keyStore = bundle.keyValueStore;
        commitLog = keyStore.commitLog!;
      });

      tearDown(() async {
        await factory.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('put with skipCommit purges the existing commit entry and '
          'returns -1', () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNotNull);

        final result = await keyStore.put(
            'phone.wavi@alice', AtData()..data = 'v2',
            skipCommit: true);
        expect(result, -1);
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNull,
            reason: 'a no-commit write scrubs the key\'s previous entry — '
                'sync must not serve a stale entry for a record whose '
                'latest change was deliberately uncommitted');
        expect((await keyStore.get('phone.wavi@alice'))!.data, 'v2',
            reason: 'the write itself still happens');
      });

      test('create with skipCommit purges the DELETE entry left by an '
          'earlier remove', () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        await keyStore.remove('phone.wavi@alice');
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice')!.operation,
            CommitOp.DELETE);

        final result = await keyStore.create(
            'phone.wavi@alice', AtData()..data = 'v2',
            skipCommit: true);
        expect(result, -1);
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNull);
      });

      test('putMeta with skipCommit purges and returns -1', () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNotNull);

        final result = await keyStore.putMeta(
            'phone.wavi@alice', AtMetaData()..ttl = 60000,
            skipCommit: true);
        expect(result, -1);
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNull);
        expect((await keyStore.getMeta('phone.wavi@alice'))!.ttl, 60000,
            reason: 'the metadata write itself still happens');
      });

      test('remove with skipCommit purges even when the key is already gone',
          () async {
        // The cruft case: a commit entry for a key that no longer exists.
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        await keyStore.remove('phone.wavi@alice');
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNotNull,
            reason: 'a normal delete leaves a DELETE entry (the cruft)');

        final result =
            await keyStore.remove('phone.wavi@alice', skipCommit: true);
        expect(result, -1);
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNull,
            reason: 'no-commit delete of an already-deleted key must still '
                'purge the entry — that is the whole point of commit-log '
                'cruft management');
      });

      test('removeMany with skipCommit purges every key\'s entry', () async {
        await keyStore.put('a.wavi@alice', AtData()..data = '1');
        await keyStore.put('b.wavi@alice', AtData()..data = '2');
        await keyStore.put('c.wavi@alice', AtData()..data = '3');

        await keyStore.removeMany(['a.wavi@alice', 'b.wavi@alice'],
            skipCommit: true);
        expect(commitLog.getLatestCommitEntry('a.wavi@alice'), isNull);
        expect(commitLog.getLatestCommitEntry('b.wavi@alice'), isNull);
        expect(commitLog.getLatestCommitEntry('c.wavi@alice'), isNotNull,
            reason: 'an untouched key keeps its entry');
      });

      test('removeEntryFor removes at most one entry and tolerates absence',
          () async {
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        await keyStore.put('other.wavi@alice', AtData()..data = 'v2');
        final countBefore = commitLog.entriesCount();

        await commitLog.removeEntryFor('phone.wavi@alice');
        expect(commitLog.getLatestCommitEntry('phone.wavi@alice'), isNull);
        expect(commitLog.getLatestCommitEntry('other.wavi@alice'), isNotNull);
        expect(commitLog.entriesCount(), countBefore - 1);

        // Removing a nonexistent entry is not an error.
        await commitLog.removeEntryFor('phone.wavi@alice');
        expect(commitLog.entriesCount(), countBefore - 1);
      });

      test('lastCommittedSequenceNumber after purging the newest entry: '
          'pinned per-backend divergence', () async {
        final id1 = await keyStore.put('a.wavi@alice', AtData()..data = '1');
        final id2 = await keyStore.put('b.wavi@alice', AtData()..data = '2');
        expect(id2! > id1!, isTrue);
        expect(commitLog.lastCommittedSequenceNumber(), id2);

        await commitLog.removeEntryFor('b.wavi@alice');
        if (backend == 'hive') {
          expect(commitLog.lastCommittedSequenceNumber(), id2,
              reason: 'Hive\'s latestCommitId is monotonic and never '
                  'decremented on purge — a phantom id pointing at a purged '
                  'entry is tolerated by sync (gaps are routine) and a '
                  'client syncing from it simply receives nothing');
        } else {
          expect(commitLog.lastCommittedSequenceNumber(), id1,
              reason: 'SQLite answers MAX(commit_id) from the table, so '
                  'purging the newest entry lowers the reported ceiling');
        }
      });

      test('remove(deletedAt:) records the asserted time as the DELETE '
          'entry\'s opTime', () async {
        final dAt = DateTime.utc(2023, 5, 5, 11, 59, 44, 123);
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        await keyStore.remove('phone.wavi@alice', deletedAt: dAt);
        final entry = commitLog.getLatestCommitEntry('phone.wavi@alice')!;
        expect(entry.operation, CommitOp.DELETE);
        expect(entry.opTime, dAt);
      });

      test('put with asserted updatedAt records it as the entry\'s opTime',
          () async {
        final uAt = DateTime.utc(2023, 6, 6, 10, 30, 0, 500);
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1',
            assertedTimestamps: AtAssertedTimestamps(updatedAt: uAt));
        final entry = commitLog.getLatestCommitEntry('phone.wavi@alice')!;
        expect(entry.opTime, uAt);
      });

      test('without an asserted time, opTime is stamped now', () async {
        final before = DateTime.now().toUtcMillisecondsPrecision();
        await keyStore.put('phone.wavi@alice', AtData()..data = 'v1');
        final after = DateTime.now().toUtcMillisecondsPrecision();
        final opTime =
            commitLog.getLatestCommitEntry('phone.wavi@alice')!.opTime!;
        expect(opTime.isBefore(before), isFalse);
        expect(opTime.isAfter(after), isFalse);
      });
    });
  }
}
