import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// Commit ids as a sync client sees them: the same numbering on every
/// backend, and an id once issued is never issued again or forgotten.
void main() {
  const atSign = '@alice';
  late Directory root;
  var dirs = 0;

  setUp(() => root = Directory.systemTemp.createTempSync('commit_id_hwm'));
  tearDown(() async {
    await HiveInstances.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String newDir() =>
      (Directory('${root.path}/${dirs++}')..createSync(recursive: true)).path;

  AtData data(String v) => AtData()..data = v;

  /// Starts one backend's store at [dir], as the atServer does at start-up.
  Future<(AtPersistenceFactory, AtPersistenceBundle)> start(
      String backend, String dir) async {
    if (backend == 'hive') {
      final factory = HiveAtPersistenceFactory();
      return (
        factory,
        await factory.initialize(
            atSign,
            HivePersistenceConfig(
                storagePath: '$dir/hive',
                commitLogPath: '$dir/commitLog',
                accessLogPath: '$dir/accessLog',
                notificationStoragePath: '$dir/notificationLog'))
      );
    }
    final factory = SqliteAtPersistenceFactory();
    return (
      factory,
      await factory.initialize(
          atSign, SqlitePersistenceConfig(storagePath: dir))
    );
  }

  int? lastCommitId(AtPersistenceBundle bundle) =>
      bundle.keyValueStore.commitLog!.lastCommittedSequenceNumber();

  /// Removes from disk every trace of the commit-log records already deleted,
  /// which is what Hive's own compaction does once enough have accumulated.
  Future<void> compactStorage(AtPersistenceBundle bundle) async {
    final commitLog = bundle.keyValueStore.commitLog;
    if (commitLog is HiveAtCommitLog) {
      await commitLog.commitLogKeyStore.getBox().compact();
    }
  }

  /// Writes `a` and `b`, then rewrites `b` with no commit, which purges `b`'s
  /// entry: the newest in the log. Returns the id `b` was issued.
  Future<int> purgeNewest(AtPersistenceBundle bundle) async {
    final store = bundle.keyValueStore;
    await store.create('a.app@alice', data('a'));
    final purgedId = (await store.create('b.app@alice', data('b')))!;
    await store.put('b.app@alice', data('b2'), skipCommit: true);
    expect(store.commitLog!.getLatestCommitEntry('b.app@alice'), isNull,
        reason: 'the purge this test depends on did not happen');
    return purgedId;
  }

  for (final backend in ['hive', 'sqlite']) {
    group('$backend:', () {
      test('commit ids are numbered from 0', () async {
        final (_, bundle) = await start(backend, newDir());
        final store = bundle.keyValueStore;
        expect(lastCommitId(bundle), -1,
            reason: 'an empty log has issued no id');
        expect(await store.create('a.app@alice', data('1')), 0);
        expect(await store.put('a.app@alice', data('2')), 1);
        expect(await store.create('b.app@alice', data('3')), 2);
        expect(await store.remove('a.app@alice'), 3);
        expect(lastCommitId(bundle), 3);
      });

      test('clearing the store starts the numbering again', () async {
        final (_, bundle) = await start(backend, newDir());
        await bundle.keyValueStore.create('a.app@alice', data('1'));
        final first =
            await bundle.keyValueStore.create('b.app@alice', data('2'));
        await bundle.clear();
        expect(lastCommitId(bundle), -1);
        expect(await bundle.keyValueStore.create('c.app@alice', data('3')),
            first! - 1,
            reason: 'after a clear the store numbers as a fresh one does');
      });

      test('the last commit id survives a purge of the newest entry', () async {
        final dir = newDir();
        var (factory, bundle) = await start(backend, dir);
        final purgedId = await purgeNewest(bundle);
        expect(lastCommitId(bundle), purgedId,
            reason: 'the purged id was issued, and a client may already '
                'hold it');
        await compactStorage(bundle);
        await factory.close();

        (factory, bundle) = await start(backend, dir);
        expect(lastCommitId(bundle), purgedId,
            reason: 'a restart must not change the last commit id when '
                'nothing was written');
      });

      test('concurrent writes are issued distinct ids', () async {
        final (_, bundle) = await start(backend, newDir());
        final ids = await Future.wait([
          for (var i = 0; i < 20; i++)
            bundle.keyValueStore.create('k$i.app@alice', data('$i'))
        ]);
        expect(ids.toSet(), hasLength(20),
            reason: 'two writes in flight together must not share an id');
      });

      test('a commit after a replay is issued an id above the replayed ones',
          () async {
        final (_, bundle) = await start(backend, newDir());
        final commitLog = bundle.keyValueStore.commitLog!;
        for (var id = 0; id < 3; id++) {
          await commitLog.replay(
              CommitEntry('r$id.app@alice', CommitOp.UPDATE, DateTime.now())
                ..commitId = id);
        }
        expect(await bundle.keyValueStore.create('new.app@alice', data('n')), 3,
            reason: 'an id below 3 would overwrite a replayed entry');
      });

      test('a purged newest id is not issued again after a restart', () async {
        final dir = newDir();
        var (factory, bundle) = await start(backend, dir);
        final purgedId = await purgeNewest(bundle);
        await compactStorage(bundle);
        await factory.close();

        (factory, bundle) = await start(backend, dir);
        expect(await bundle.keyValueStore.create('c.app@alice', data('c')),
            purgedId + 1,
            reason: 'a client that pulled the purged id asks for ids above '
                'it, so a second one would never reach it');
      });
    });
  }

  for (final (from, to) in [('hive', 'sqlite'), ('sqlite', 'hive')]) {
    test('migrating $from to $to carries the last commit id across', () async {
      final (_, source) = await start(from, newDir());
      final purgedId = await purgeNewest(source);
      final targetDir = newDir();
      var (factory, target) = await start(to, targetDir);
      await PersistenceMigrator.migrate(source, target);

      expect(lastCommitId(target), purgedId,
          reason: 'the replayed entries stop below the purged id, which was '
              'issued all the same');
      await compactStorage(target);
      await factory.close();
      (factory, target) = await start(to, targetDir);
      expect(await target.keyValueStore.create('c.app@alice', data('c')),
          purgedId + 1,
          reason: 'the target must issue next what the source would');
    });
  }
}
