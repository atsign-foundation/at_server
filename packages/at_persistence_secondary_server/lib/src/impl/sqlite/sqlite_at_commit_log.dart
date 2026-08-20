import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_database.dart';

/// SQLite-backed [AtCommitLog]. One row per atKey, newest-wins, with a
/// dense/gapless `commit_id` allocated from the `counters` table in the
/// same transaction as the keystore write (see [commitSync]).
class SqliteAtCommitLog extends AtCommitLog {
  final SqliteDatabase _db;

  SqliteAtCommitLog(this._db);

  /// True for atKeys that never get a commit-log row (and so never
  /// consume a commit id): `private:` / `privatekey:` / `public:_`
  /// (single underscore) / `local:` — EXCEPT `public:__` (double
  /// underscore), which IS synced. Mirrors `hive_at_commit_log.dart`.
  static final RegExp _elidedPrefixes =
      RegExp('^(private:|privatekey:|public:_|local:)');

  bool _isElided(String key) =>
      !key.startsWith('public:__') && _elidedPrefixes.hasMatch(key);

  /// Synchronous commit used inside a keystore write's transaction so
  /// the value row and its commit entry are one atomic unit. Returns the
  /// allocated commit id, or `-1` for an elided key. Re-entrant via
  /// [SqliteDatabase.runInTransaction]: joins the caller's transaction
  /// when there is one, else opens its own.
  ///
  /// [opTime] as on [AtCommitLog.commit]: caller-asserted operation
  /// time when supplied, else now.
  int? commitSync(String atKey, CommitOp operation, {DateTime? opTime}) {
    if (_isElided(atKey)) return -1;
    return _db.runInTransaction(() {
      _db.raw.execute(
          "UPDATE counters SET value = value + 1 WHERE name = 'last_commit_id';");
      final commitId = _db.raw
          .select("SELECT value FROM counters WHERE name = 'last_commit_id';")
          .first
          .values
          .first as int;
      _db.raw.execute(
        'INSERT INTO commit_log (atkey, commit_id, operation, op_time) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(atkey) DO UPDATE SET '
        'commit_id = excluded.commit_id, operation = excluded.operation, '
        'op_time = excluded.op_time;',
        [
          atKey,
          commitId,
          operation.name,
          (opTime ?? DateTime.now())
              .toUtcMillisecondsPrecision()
              .millisecondsSinceEpoch,
        ],
      );
      return commitId;
    });
  }

  /// Delete the commit-log row for [atKey] (expiry / skipCommit path).
  /// No counter bump. Re-entrant. An expired key must not be
  /// resurrectable by a sync client replaying an old commit entry.
  void purgeSync(String atKey) {
    _db.raw.execute('DELETE FROM commit_log WHERE atkey = ?;', [atKey]);
  }

  @override
  Future<int?> commit(String key, CommitOp operation,
          {DateTime? opTime}) async =>
      commitSync(key, operation, opTime: opTime);

  @override
  Future<void> removeEntryFor(String key) async => purgeSync(key);

  @override
  Future<void> replay(CommitEntry entry) async {
    if (entry.commitId == null) {
      throw DataStoreException('replay requires a non-null commitId');
    }
    _db.runInTransaction(() {
      _db.raw.execute(
        'INSERT INTO commit_log (atkey, commit_id, operation, op_time) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(atkey) DO UPDATE SET '
        'commit_id = excluded.commit_id, operation = excluded.operation, '
        'op_time = excluded.op_time;',
        [
          entry.atKey,
          entry.commitId,
          entry.operation.name,
          entry.opTime?.toUtc().millisecondsSinceEpoch,
        ],
      );
      // Keep the allocator ahead of every replayed id so subsequent live
      // commits stay monotonic and never collide with a migrated id.
      _db.raw.execute(
          "UPDATE counters SET value = MAX(value, ?) WHERE name = 'last_commit_id';",
          [entry.commitId]);
    });
  }

  @override
  Stream<CommitEntry> iterate({
    int? fromCommitId,
    bool Function(CommitEntry)? where,
    int? skipDeletesUntil,
    int? latestCommitId,
  }) async* {
    if (skipDeletesUntil != null) {
      yield* _iterateSkippingDeletes(
          fromCommitId ?? 0, skipDeletesUntil, latestCommitId, where);
      return;
    }
    final sql = StringBuffer(
        'SELECT atkey, commit_id, operation, op_time FROM commit_log ');
    final params = <Object?>[];
    if (fromCommitId != null) {
      sql.write('WHERE commit_id >= ? ');
      params.add(fromCommitId);
    }
    sql.write('ORDER BY commit_id;');
    yield* _cursor(sql.toString(), params, where);
  }

  /// The skip-deletes traversal, expressed as index-driven range scans
  /// rather than a `NOT (operation = '-' ...)` filter over the full
  /// commit_id index.
  ///
  /// The `NOT (...)` form is correct but reads every row: its plan is
  /// `SEARCH ... USING INDEX commit_log_commit_id (commit_id>?)`, which
  /// seeks to [fromCommitId] and then walks to the end evaluating the
  /// predicate on each row -- so a client near the tail of a
  /// delete-dominated log still causes a walk of the whole log in SQLite's
  /// C layer (it just no longer materialises the deletes into Dart). The
  /// decomposition below lets the partial index `commit_log_live` seek
  /// straight to the live rows instead. Measured on a 1M-entry log holding
  /// one live entry: the full-scan form is ~0.5-0.6s, this is sub-ms.
  ///
  ///   segment 1  live rows in [from .. skipDeletesUntil]  -> commit_log_live
  ///   kept       the entry at [latestCommitId], if that is a below-
  ///              watermark DELETE (a live one is already in segment 1, an
  ///              above-watermark one in segment 2)
  ///   segment 2  every op with commit_id > skipDeletesUntil -> commit_log_commit_id
  ///
  /// Ordering: segment 1 ids are all <= skipDeletesUntil < segment 2 ids,
  /// so the two segments are globally ascending without a sort step. The
  /// kept entry only exists when `latestCommitId <= skipDeletesUntil`; a
  /// truthful [latestCommitId] is the store's max commit id, so nothing
  /// sits above it and segment 2 is empty whenever the kept entry fires --
  /// it is therefore the largest id in the stream and emitting it between
  /// the segments keeps the output ordered.
  Stream<CommitEntry> _iterateSkippingDeletes(
    int fromCommitId,
    int skipDeletesUntil,
    int? latestCommitId,
    bool Function(CommitEntry)? where,
  ) async* {
    // segment 1
    yield* _cursor(
      'SELECT atkey, commit_id, operation, op_time FROM commit_log '
      "WHERE commit_id >= ? AND commit_id <= ? AND operation <> '-' "
      'ORDER BY commit_id;',
      [fromCommitId, skipDeletesUntil],
      where,
    );
    // kept latest entry (only when it is a skipped below-watermark DELETE;
    // matching `operation = '-'` also avoids double-emitting a live entry
    // that segment 1 already yielded)
    if (latestCommitId != null &&
        latestCommitId >= fromCommitId &&
        latestCommitId <= skipDeletesUntil) {
      yield* _cursor(
        'SELECT atkey, commit_id, operation, op_time FROM commit_log '
        "WHERE commit_id = ? AND operation = '-';",
        [latestCommitId],
        where,
      );
    }
    // segment 2 -- one lower bound only. Writing `commit_id >= from AND
    // commit_id > skipDeletesUntil` makes SQLite seek on one bound and
    // filter the other row-by-row (a plan that still reads "SEARCH ...
    // USING INDEX" while walking the whole span), so collapse the two to
    // their max here.
    final lower = fromCommitId > skipDeletesUntil + 1
        ? fromCommitId
        : skipDeletesUntil + 1;
    yield* _cursor(
      'SELECT atkey, commit_id, operation, op_time FROM commit_log '
      'WHERE commit_id >= ? ORDER BY commit_id;',
      [lower],
      where,
    );
  }

  /// Streams [sql] lazily via a prepared cursor, applying [where] and
  /// disposing the statement even if the consumer stops early.
  ///
  /// `select()` is eager -- it materialises the whole result set into a
  /// Dart list before the first row is seen. Callers of iterate() routinely
  /// stop early (sync's prepareResponse breaks after one page), so on a
  /// large log the eager form allocated every row to return a handful; an
  /// ordinary sync returning 25 entries measured 501ms this way against
  /// 0.16ms on Hive. A cursor does work proportional to what is consumed.
  Stream<CommitEntry> _cursor(
    String sql,
    List<Object?> params,
    bool Function(CommitEntry)? where,
  ) async* {
    final stmt = _db.raw.prepare(sql);
    try {
      final cursor = stmt.selectCursor(params);
      while (cursor.moveNext()) {
        final entry = _entryFromRow(cursor.current);
        if (where == null || where(entry)) yield entry;
      }
    } finally {
      // Runs on early termination too: a consumer breaking its `await for`
      // closes the stream, resuming this generator at the yield to unwind
      // here, so the statement is never leaked.
      stmt.dispose();
    }
  }

  @override
  int? lastCommittedSequenceNumber() => _minMax('MAX');

  @override
  int? firstCommittedSequenceNumber() => _minMax('MIN');

  @override
  CommitEntry? getLatestCommitEntry(String key) {
    final rows = _db.raw.select(
        'SELECT atkey, commit_id, operation, op_time FROM commit_log '
        'WHERE atkey = ?;',
        [key]);
    return rows.isEmpty ? null : _entryFromRow(rows.first);
  }

  @override
  int entriesCount() =>
      _db.raw.select('SELECT COUNT(*) c FROM commit_log;').first['c'] as int;

  /// Size in KB, matching the spec and [HiveBase.getSize] -- this returned
  /// raw bytes, over-reporting by 1024x.
  @override
  int getSize() => _dbFileSize(_db.path) ~/ 1024;

  @override
  Future<void> close() async {
    // The connection is owned by the shared SqliteDatabase and closed by
    // the bundle; individual stores do not close it.
  }

  @override
  Stream<int> compact(bool dryRun) async* {
    // One row per atKey by construction — there are no duplicate entries
    // to prune, so compaction is a no-op on this backend.
  }

  int? _minMax(String fn) {
    final v =
        _db.raw.select('SELECT $fn(commit_id) v FROM commit_log;').first['v'];
    return v as int?;
  }

  CommitEntry _entryFromRow(Row row) {
    final op = _opFromSymbol(row['operation'] as String);
    final opTimeMillis = row['op_time'] as int?;
    final opTime = opTimeMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(opTimeMillis, isUtc: true);
    return CommitEntry(row['atkey'] as String, op, opTime)
      ..commitId = row['commit_id'] as int?;
  }

  static CommitOp _opFromSymbol(String symbol) {
    switch (symbol) {
      case '+':
        return CommitOp.UPDATE;
      case '#':
        return CommitOp.UPDATE_META;
      case '*':
        return CommitOp.UPDATE_ALL;
      case '-':
        return CommitOp.DELETE;
      default:
        throw DataStoreException('Unknown commit operation symbol: $symbol');
    }
  }
}

/// Approximate on-disk size: the main db file plus any `-wal` sidecar.
int _dbFileSize(String path) {
  var total = 0;
  for (final suffix in ['', '-wal']) {
    final f = File('$path$suffix');
    if (f.existsSync()) total += f.lengthSync();
  }
  return total;
}
