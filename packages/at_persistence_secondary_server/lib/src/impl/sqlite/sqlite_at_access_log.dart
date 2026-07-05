import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_database.dart';

/// SQLite-backed [AtAccessLog] (`access_log` table). Insert-only verb /
/// connection audit; `seq` is the rowid alias, so insertion order is id
/// order.
class SqliteAtAccessLog implements AtAccessLog {
  final SqliteDatabase _db;

  /// Percentage of oldest entries dropped per compaction pass.
  final int compactionPercentage;

  SqliteAtAccessLog(this._db, {this.compactionPercentage = 30});

  @override
  Future<int?> insert(String fromAtSign, String verbName,
      {String? lookupKey}) async {
    return _db.runInTransaction(() {
      _db.raw.execute(
        'INSERT INTO access_log (from_atsign, request_at, verb_name, lookup_key) '
        'VALUES (?, ?, ?, ?);',
        [
          fromAtSign,
          DateTime.now().toUtc().millisecondsSinceEpoch,
          verbName,
          lookupKey
        ],
      );
      return _db.raw.select('SELECT last_insert_rowid() r;').first['r'] as int;
    });
  }

  @override
  Future<void> replay(AccessLogEntry entry) async {
    _db.raw.execute(
      'INSERT INTO access_log (from_atsign, request_at, verb_name, lookup_key) '
      'VALUES (?, ?, ?, ?);',
      [
        entry.fromAtSign,
        entry.requestDateTime?.toUtc().millisecondsSinceEpoch,
        entry.verbName,
        entry.lookupKey
      ],
    );
  }

  @override
  Future<Map<String, int>> mostVisitedAtSigns(int length) async {
    final rows = _db.raw.select(
        "SELECT from_atsign a, COUNT(*) c FROM access_log WHERE verb_name = 'pol' "
        'AND from_atsign IS NOT NULL GROUP BY from_atsign ORDER BY c DESC LIMIT ?;',
        [length]);
    return {for (final r in rows) r['a'] as String: r['c'] as int};
  }

  @override
  Future<Map<String, int>> mostVisitedKeys(int length) async {
    final rows = _db.raw.select(
        "SELECT lookup_key k, COUNT(*) c FROM access_log WHERE verb_name = 'lookup' "
        'AND lookup_key IS NOT NULL GROUP BY lookup_key ORDER BY c DESC LIMIT ?;',
        [length]);
    return {for (final r in rows) r['k'] as String: r['c'] as int};
  }

  @override
  Future<AccessLogEntry> getLastAccessLogEntry() async {
    final rows = _db.raw.select(
        'SELECT from_atsign, request_at, verb_name, lookup_key FROM access_log '
        'ORDER BY seq DESC LIMIT 1;');
    if (rows.isEmpty) {
      throw StateError('access_log is empty');
    }
    return _entryFromRow(rows.first);
  }

  @override
  Future<AccessLogEntry?> getLastPkamAccessLogEntry() async {
    final rows = _db.raw.select(
        "SELECT from_atsign, request_at, verb_name, lookup_key FROM access_log "
        "WHERE verb_name = 'pkam' ORDER BY request_at DESC, seq DESC LIMIT 1;");
    return rows.isEmpty ? null : _entryFromRow(rows.first);
  }

  @override
  Stream<AccessLogEntry> iterate() async* {
    final rows = _db.raw.select(
        'SELECT from_atsign, request_at, verb_name, lookup_key FROM access_log '
        'ORDER BY seq;');
    for (final r in rows) {
      yield _entryFromRow(r);
    }
  }

  @override
  int entriesCount() =>
      _db.raw.select('SELECT COUNT(*) c FROM access_log;').first['c'] as int;

  @override
  int getSize() {
    final f = File(_db.path);
    return f.existsSync() ? f.lengthSync() : 0;
  }

  @override
  Future<void> close() async {}

  /// Drops all rows (keeping the connection open) for test isolation.
  Future<void> clear() async {
    _db.raw.execute('DELETE FROM access_log;');
  }

  @override
  Stream<int> compact(bool dryRun) async* {
    final total = entriesCount();
    final firstN = (total * (compactionPercentage / 100)).toInt();
    if (firstN <= 0) return;
    final ids = _db.raw
        .select('SELECT seq FROM access_log ORDER BY seq LIMIT ?;', [firstN])
        .map((r) => r['seq'] as int)
        .toList();
    if (dryRun) {
      yield* Stream.fromIterable(ids);
      return;
    }
    _db.runInTransaction(() {
      for (final id in ids) {
        _db.raw.execute('DELETE FROM access_log WHERE seq = ?;', [id]);
      }
    });
    yield* Stream.fromIterable(ids);
  }

  AccessLogEntry _entryFromRow(Row row) {
    final millis = row['request_at'] as int?;
    return AccessLogEntry(
      row['from_atsign'] as String?,
      millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
      row['verb_name'] as String?,
      row['lookup_key'] as String?,
    );
  }
}
