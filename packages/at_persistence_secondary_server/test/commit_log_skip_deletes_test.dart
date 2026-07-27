import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// Query-level `skipDeletesUntil` for sync.
///
/// [AtCommitLog.iterate] filters below-watermark DELETE entries itself — in
/// SQLite, in the query, so those rows are never materialised — while always
/// yielding the single latest entry so the client can advance its watermark.
/// Runs identically against both backends.
void main() {
  for (final backend in ['hive', 'sqlite']) {
    group('$backend commit log iterate(skipDeletesUntil:)', () {
      late Directory tempDir;
      late AtPersistenceFactory factory;
      late AtCommitLog commitLog;

      // Commit ids of the entries seeded in setUp.
      late int idU1, idD1, idD2;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('skip_deletes_');
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
        commitLog = bundle.keyValueStore.commitLog!;

        // Seed: two UPDATE-only keys and two keys ending in DELETE, at
        // increasing commit ids. The one-entry-per-atKey dedup invariant keeps
        // the DELETE entry for the deleted keys (the interim UPDATE is dropped).
        idU1 = (await commitLog.commit('public:u1@alice', CommitOp.UPDATE))!;
        await commitLog.commit('public:d1@alice', CommitOp.UPDATE);
        idD1 = (await commitLog.commit('public:d1@alice', CommitOp.DELETE))!;
        await commitLog.commit('public:u2@alice', CommitOp.UPDATE);
        await commitLog.commit('public:d2@alice', CommitOp.UPDATE);
        idD2 = (await commitLog.commit('public:d2@alice', CommitOp.DELETE))!;
      });

      tearDown(() async {
        await factory.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      Future<List<String?>> keysFrom(Stream<CommitEntry> s) async =>
          (await s.toList()).map((e) => e.atKey).toList();

      test('skips a below-watermark DELETE, keeps UPDATEs and later DELETEs',
          () async {
        final keys = await keysFrom(commitLog.iterate(
            fromCommitId: idU1, skipDeletesUntil: idD1, latestCommitId: idD2));
        expect(keys, isNot(contains('public:d1@alice')),
            reason: 'below-watermark DELETE must be filtered by the query');
        expect(
            keys,
            containsAll(<String>[
              'public:u1@alice', // UPDATE below watermark - kept
              'public:u2@alice', // UPDATE - kept
              'public:d2@alice', // DELETE above watermark - kept
            ]));
      });

      test('always keeps the latest entry even if it is a below-watermark '
          'DELETE', () async {
        // Threshold at the latest delete: d1 is dropped, but d2 (== latest) is
        // retained so the client can still advance its commit id.
        final keys = await keysFrom(commitLog.iterate(
            fromCommitId: idU1, skipDeletesUntil: idD2, latestCommitId: idD2));
        expect(keys, isNot(contains('public:d1@alice')));
        expect(keys, contains('public:d2@alice'),
            reason: 'the latest commit entry is always yielded');
      });

      test('with latestCommitId omitted (null), no below-watermark DELETE '
          'survives — not even the latest', () async {
        // Mirror of the previous test with latestCommitId left null: there is
        // then no keep-latest exemption, so d2 is dropped too. This pins the
        // SQLite `?? -1` fallback and the Hive null-compare to the same
        // "exempt nothing" behaviour across both backends.
        final keys = await keysFrom(
            commitLog.iterate(fromCommitId: idU1, skipDeletesUntil: idD2));
        expect(keys, isNot(contains('public:d1@alice')));
        expect(keys, isNot(contains('public:d2@alice')),
            reason: 'without latestCommitId there is no keep-latest exemption');
        expect(
            keys, containsAll(<String>['public:u1@alice', 'public:u2@alice']));
      });

      test('without skipDeletesUntil, every entry (incl. deletes) is yielded',
          () async {
        final keys = await keysFrom(commitLog.iterate(fromCommitId: idU1));
        expect(
            keys,
            containsAll(<String>[
              'public:u1@alice',
              'public:d1@alice',
              'public:u2@alice',
              'public:d2@alice',
            ]));
      });
    });
  }
}
