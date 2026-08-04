import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/sqlite.dart';
import 'package:test/test.dart';

/// `iterate(skipDeletesUntil: ...)` is an optimization hint: it must yield
/// exactly what the caller's own predicate would have selected anyway. These
/// tests pin that equivalence on BOTH backends, so a backend implementing
/// the pushdown (SQLite) cannot silently diverge from one that ignores it
/// (Hive).
///
/// The reference predicate is the one the sync handler applies -- see
/// `whereFilter` in sync_progressive_verb_handler.dart.
bool Function(CommitEntry) reference(int skipDeletesUntil, int? latest) {
  return (e) => !(e.operation == CommitOp.DELETE &&
      e.commitId != null &&
      e.commitId! <= skipDeletesUntil &&
      e.commitId != latest);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('skip_deletes_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Builds a log of [total] entries where every entry is a DELETE except
  /// those whose 1-based position is in [liveAt].
  Future<void> seed(AtCommitLog log, int total, Set<int> liveAt) async {
    for (var i = 1; i <= total; i++) {
      await log.commit('public:k$i@alice',
          liveAt.contains(i) ? CommitOp.UPDATE : CommitOp.DELETE);
    }
  }

  Future<AtCommitLog> hiveLog() async {
    final f = HiveAtPersistenceFactory();
    addTearDown(f.close);
    final b = await f.initialize(
      '@alice',
      HivePersistenceConfig.serverDefaults(
        storagePath: '${tempDir.path}/hive/storage',
        commitLogPath: '${tempDir.path}/hive/commitLog',
        accessLogPath: '${tempDir.path}/hive/accessLog',
        notificationStoragePath: '${tempDir.path}/hive/notification',
      ),
    );
    return b.keyValueStore.commitLog!;
  }

  Future<AtCommitLog> sqliteLog() async {
    final f = SqliteAtPersistenceFactory();
    addTearDown(f.close);
    final b = await f.initialize(
      '@alice',
      SqlitePersistenceConfig.serverDefaults(
          storagePath: '${tempDir.path}/sqlite'),
    );
    return b.keyValueStore.commitLog!;
  }

  for (final backend in ['hive', 'sqlite']) {
    group('$backend: skipDeletesUntil pushdown equivalence', () {
      Future<AtCommitLog> open() =>
          backend == 'hive' ? hiveLog() : sqliteLog();

      /// The property under test: passing the hint ALONGSIDE the caller's
      /// predicate yields exactly what the predicate alone yields.
      ///
      /// Note both sides pass `where`. The hint is not a filter in its own
      /// right -- a backend that ignores it (Hive) returns the unfiltered
      /// stream, and only the caller's predicate makes the two agree. That
      /// is the contract in AtCommitLog.iterate, and it is what the sync
      /// handler does; a test that dropped `where` from the pushed side
      /// would be asserting a property the contract never promised.
      Future<void> expectEquivalent(
        AtCommitLog log, {
        required int skipDeletesUntil,
        int? fromCommitId,
      }) async {
        final latest = log.lastCommittedSequenceNumber();
        final pushed = await log
            .iterate(
                fromCommitId: fromCommitId,
                where: reference(skipDeletesUntil, latest),
                skipDeletesUntil: skipDeletesUntil,
                latestCommitId: latest)
            .toList();
        final filtered = await log
            .iterate(
                fromCommitId: fromCommitId,
                where: reference(skipDeletesUntil, latest))
            .toList();
        expect(pushed.map((e) => e.commitId).toList(),
            filtered.map((e) => e.commitId).toList(),
            reason: 'the hint must not change which entries are selected');
        expect(pushed.map((e) => e.atKey).toList(),
            filtered.map((e) => e.atKey).toList());
      }

      test('delete-dominated log, single live entry at the end', () async {
        final log = await open();
        await seed(log, 40, {40});
        await expectEquivalent(log, skipDeletesUntil: 40);
      });

      test('live entries scattered through the log', () async {
        final log = await open();
        await seed(log, 40, {3, 17, 18, 39});
        await expectEquivalent(log, skipDeletesUntil: 40);
      });

      test('threshold below the max leaves later deletes intact', () async {
        final log = await open();
        await seed(log, 40, {5});
        await expectEquivalent(log, skipDeletesUntil: 20);
      });

      test('combines with fromCommitId', () async {
        final log = await open();
        await seed(log, 40, {5, 33});
        await expectEquivalent(log, skipDeletesUntil: 40, fromCommitId: 10);
      });

      test('all entries are deletes: latest is still yielded so the '
          'client can advance its watermark', () async {
        final log = await open();
        await seed(log, 12, {});
        final latest = log.lastCommittedSequenceNumber()!;
        final selected = await log
            .iterate(
                where: reference(latest, latest),
                skipDeletesUntil: latest,
                latestCommitId: latest)
            .toList();
        expect(selected.map((e) => e.commitId), [latest],
            reason: 'exactly the latest entry, even though it is a DELETE');
        await expectEquivalent(log, skipDeletesUntil: latest);
      });

      test('threshold above the max still yields the latest entry', () async {
        final log = await open();
        await seed(log, 12, {});
        final latest = log.lastCommittedSequenceNumber()!;
        await expectEquivalent(log, skipDeletesUntil: latest + 5000);
      });

      test('empty log yields nothing', () async {
        final log = await open();
        expect(
            await log
                .iterate(where: reference(100, null), skipDeletesUntil: 100)
                .toList(),
            isEmpty);
      });

      test('no deletes at all: every entry survives', () async {
        final log = await open();
        await seed(log, 10, {for (var i = 1; i <= 10; i++) i});
        await expectEquivalent(log, skipDeletesUntil: 10);
      });
    });
  }

  group('sqlite: the pushdown actually uses the partial index', () {
    test('skip-deletes range scan is planned on commit_log_live', () async {
      final db = SqliteDatabase.open('@alice', '${tempDir.path}/plan.db');
      addTearDown(db.close);
      final plan = db.raw
          .select('EXPLAIN QUERY PLAN '
              'SELECT atkey, commit_id, operation, op_time FROM commit_log '
              "WHERE commit_id >= ? AND commit_id <= ? AND operation <> '-' "
              'ORDER BY commit_id;', [1, 100])
          .map((r) => r['detail'] as String)
          .join(' | ');
      // Without this the pushdown still returns correct rows, but degrades
      // to a full scan -- correct and slow, which no equivalence test above
      // would catch.
      expect(plan, contains('commit_log_live'),
          reason: 'plan was: $plan');
    });

    test('an existing database acquires the index on open, with no '
        'contract-version bump', () async {
      final path = '${tempDir.path}/existing.db';
      final first = SqliteDatabase.open('@alice', path);
      final version = first.raw.select('PRAGMA user_version;').first.values.first;
      first.raw.execute('DROP INDEX IF EXISTS commit_log_live;');
      first.close();

      final reopened = SqliteDatabase.open('@alice', path);
      addTearDown(reopened.close);
      final indexes = reopened.raw
          .select("SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND tbl_name = 'commit_log';")
          .map((r) => r['name'] as String)
          .toSet();
      expect(indexes, contains('commit_log_live'));
      expect(reopened.raw.select('PRAGMA user_version;').first.values.first,
          version,
          reason: 'an index addition must not bump the contract version, '
              'which would block rollback');
    });
  });
}
