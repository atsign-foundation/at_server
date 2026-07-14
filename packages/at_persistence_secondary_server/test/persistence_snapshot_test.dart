import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// Verifies the commit-log tolerance in [PersistenceSnapshot]. Hive can leave a
/// stale non-delete commit entry in its box for an expired (or removed) key
/// after a TTL-expiry `skipCommit` sweep — its cache-based purge misses the box
/// entry — while a faithful SQLite mirror carries no such entry. Such an entry
/// is sync-benign, so the snapshot skips non-delete commit entries whose key is
/// not present-and-unexpired. DELETE entries and live-unexpired-key entries are
/// always compared, so real mirror data loss still fails the comparison.
void main() {
  final root = '${Directory.current.path}/test/snapshot_tmp';
  late SqliteAtPersistenceFactory fa, fb;

  AtData live(String v) => AtData()
    ..data = v
    ..metaData = (AtMetaData()
      ..createdAt = DateTime.utc(2021)
      ..updatedAt = DateTime.utc(2021)
      ..version = 0);

  AtData expired(String v) => AtData()
    ..data = v
    ..metaData = (AtMetaData()
      ..createdAt = DateTime.utc(2021)
      ..updatedAt = DateTime.utc(2021)
      ..version = 0
      ..ttl = 200
      ..expiresAt = DateTime.utc(2021, 1, 1, 0, 0, 0, 200));

  setUp(() {
    fa = SqliteAtPersistenceFactory();
    fb = SqliteAtPersistenceFactory();
  });
  tearDown(() async {
    await fa.close();
    await fb.close();
    final d = Directory(root);
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  Future<List<AtPersistenceBundle>> two() async => [
        await fa.initialize('@a',
            SqlitePersistenceConfig.serverDefaults(storagePath: '$root/a')),
        await fb.initialize('@a',
            SqlitePersistenceConfig.serverDefaults(storagePath: '$root/b')),
      ];

  Future<List<String>> diffs(
          AtPersistenceBundle a, AtPersistenceBundle b) async =>
      (await PersistenceSnapshot.capture(a))
          .differencesFrom(await PersistenceSnapshot.capture(b));

  test('non-delete commit for an expired key is tolerated', () async {
    final bs = await two();
    final a = bs[0], b = bs[1];

    // Both hold the same live key (row + commit) and the same expired key row.
    for (final bundle in bs) {
      await bundle.keyValueStore.restore('k.wavi@a', live('v'));
      await bundle.keyValueStore.commitLog!.replay(
          CommitEntry('k.wavi@a', CommitOp.UPDATE_ALL, DateTime.utc(2021))
            ..commitId = 1);
      await bundle.keyValueStore.restore('ttlkey.wavi@a', expired('x'));
    }
    expect(await diffs(a, b), isEmpty);

    // Only A carries the expired key's stale commit entry (the Hive orphan).
    await a.keyValueStore.commitLog!.replay(
        CommitEntry('ttlkey.wavi@a', CommitOp.UPDATE_ALL, DateTime.utc(2021))
          ..commitId = 50);
    expect(await diffs(a, b), isEmpty,
        reason: 'a non-delete commit for an expired key must be tolerated');
  });

  test('non-delete commit for a live unexpired key is compared', () async {
    final bs = await two();
    final a = bs[0], b = bs[1];

    // Both hold the same live key row (unexpired), but only A has its commit.
    for (final bundle in bs) {
      await bundle.keyValueStore.restore('live.wavi@a', live('v'));
    }
    await a.keyValueStore.commitLog!.replay(
        CommitEntry('live.wavi@a', CommitOp.UPDATE_ALL, DateTime.utc(2021))
          ..commitId = 7);
    expect(await diffs(a, b), isNotEmpty,
        reason: 'a live unexpired key\'s commit entry must be compared');
  });

  test('DELETE commit is always compared', () async {
    final bs = await two();
    final a = bs[0], b = bs[1];

    // A DELETE entry legitimately has no keystore row; it must still be compared.
    await a.keyValueStore.commitLog!.replay(
        CommitEntry('gone.wavi@a', CommitOp.DELETE, DateTime.utc(2021))
          ..commitId = 9);
    expect(await diffs(a, b), isNotEmpty,
        reason: 'delete entries must always be compared');
  });
}
