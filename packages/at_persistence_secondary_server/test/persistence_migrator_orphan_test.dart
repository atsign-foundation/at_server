import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// The migrator drops ORPHANED commit entries — non-delete entries whose key
/// is absent from the keystore. The Hive backend accumulates these (its
/// commit-log box and in-memory cache can disagree, and the TTL-expiry purge
/// is cache-driven, so it can miss the box row); SQLite cannot generate one.
/// Copying them forward would make them permanent residents of a backend that
/// can never produce them, so migration is where they get cleaned up.
///
/// The load-bearing negative case is the DELETE tombstone: it legitimately has
/// no keystore row, and dropping it would silently break delete propagation to
/// clients.
void main() {
  const atSign = '@alice';
  final root = '${Directory.current.path}/test/migrator_orphan_tmp';

  final hiveFactory = HiveAtPersistenceFactory();
  final sqliteFactory = SqliteAtPersistenceFactory();

  tearDown(() async {
    await hiveFactory.close();
    await sqliteFactory.close();
    final dir = Directory(root);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<AtPersistenceBundle> hiveBundle(String name) => hiveFactory.initialize(
      '$atSign-$name-key',
      HivePersistenceConfig.serverDefaults(
        storagePath: '$root/hive/$name',
        commitLogPath: '$root/hive/$name',
        accessLogPath: '$root/hive/$name',
        notificationStoragePath: '$root/hive/$name',
      ));

  Future<AtPersistenceBundle> sqliteBundle(String name) =>
      sqliteFactory.initialize('$atSign-$name-key',
          SqlitePersistenceConfig.serverDefaults(storagePath: '$root/sqlite/$name'));

  /// Plants a commit entry directly, bypassing the keystore — the shape an
  /// orphan has on disk.
  Future<void> plant(
      AtPersistenceBundle b, String atKey, CommitOp op, int commitId) async {
    await b.keyValueStore.commitLog!.replay(
        CommitEntry(atKey, op, DateTime.now().toUtc())..commitId = commitId);
  }

  Future<List<CommitEntry>> entriesOf(AtPersistenceBundle b) =>
      b.keyValueStore.commitLog!.iterate().toList();

  test('orphaned non-delete commit entry is dropped; live key survives',
      () async {
    final src = await hiveBundle('src1');
    final tgt = await sqliteBundle('tgt1');

    await src.keyValueStore.put('phone.wavi$atSign', AtData()..data = '123');
    await plant(
        src,
        'cached:@garycasey:request.1698407612096620.auth_checks.__rpcs.sshnp$atSign',
        CommitOp.UPDATE,
        500);

    final report = await PersistenceMigrator.migrate(src, tgt);

    expect(report.orphanedCommitEntries, 1);
    final keys = (await entriesOf(tgt)).map((e) => e.atKey).toList();
    expect(keys, contains('phone.wavi$atSign'));
    expect(keys.any((k) => k!.startsWith('cached:@garycasey:')), false,
        reason: 'orphan must not be carried into the target');
  });

  test('DELETE tombstone with no keystore row SURVIVES', () async {
    final src = await hiveBundle('src2');
    final tgt = await sqliteBundle('tgt2');

    // A legitimately deleted key: tombstone present, no keystore row.
    await plant(src, 'deleted.wavi$atSign', CommitOp.DELETE, 501);

    final report = await PersistenceMigrator.migrate(src, tgt);

    expect(report.orphanedCommitEntries, 0,
        reason: 'a DELETE tombstone is not an orphan');
    final entries = await entriesOf(tgt);
    expect(entries.map((e) => e.atKey), contains('deleted.wavi$atSign'));
    expect(entries.single.operation, CommitOp.DELETE);
  });

  test('expired-but-present key keeps its commit entry', () async {
    final src = await hiveBundle('src3');
    final tgt = await sqliteBundle('tgt3');

    // Expired, but the expiry sweep has not run — the keystore row is still
    // there, so the entry is NOT an orphan and must be migrated verbatim.
    await src.keyValueStore.put('temp.wavi$atSign',
        AtData()..data = 'x'..metaData = (AtMetaData()..ttl = 1));
    await Future.delayed(Duration(milliseconds: 5));

    final report = await PersistenceMigrator.migrate(src, tgt);

    expect(report.orphanedCommitEntries, 0);
    expect((await entriesOf(tgt)).map((e) => e.atKey),
        contains('temp.wavi$atSign'));
  });

  test('a clean store migrates with no orphans reported', () async {
    final src = await hiveBundle('src4');
    final tgt = await sqliteBundle('tgt4');

    await src.keyValueStore.put('a.wavi$atSign', AtData()..data = '1');
    await src.keyValueStore.put('b.wavi$atSign', AtData()..data = '2');
    await src.keyValueStore.remove('b.wavi$atSign');

    final report = await PersistenceMigrator.migrate(src, tgt);

    expect(report.orphanedCommitEntries, 0);
    expect(report.commitEntries, (await entriesOf(src)).length);
  });
}
