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
  int? commitSync(String atKey, CommitOp operation) {
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
          DateTime.now().toUtcMillisecondsPrecision().millisecondsSinceEpoch,
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
  Future<int?> commit(String key, CommitOp operation) async =>
      commitSync(key, operation);

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
    final conditions = <String>[];
    final params = <Object?>[];
    if (fromCommitId != null) {
      conditions.add('commit_id >= ?');
      params.add(fromCommitId);
    }
    if (skipDeletesUntil != null) {
      // Push sync's delete-skip into the query so below-watermark DELETE
      // rows are filtered by SQLite and never read into Dart. Keep the
      // single latest entry so the client can still advance its watermark.
      // ('-' is the DELETE operation symbol; see _opFromSymbol.)
      conditions.add("NOT (operation = '-' AND commit_id IS NOT NULL "
          'AND commit_id <= ? AND commit_id <> ?)');
      params.add(skipDeletesUntil);
      params.add(latestCommitId ?? -1);
    }
    final whereSql =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')} ';
    final rows = _db.raw.select(
        'SELECT atkey, commit_id, operation, op_time FROM commit_log '
        '${whereSql}ORDER BY commit_id;',
        params);
    for (final row in rows) {
      final entry = _entryFromRow(row);
      if (where == null || where(entry)) yield entry;
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

  @override
  int getSize() => _dbFileSize(_db.path);

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
