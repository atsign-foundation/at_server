import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_at_commit_log.dart';
import 'sqlite_database.dart';
import 'sqlite_metadata_codec.dart';
import 'sqlite_query_translator.dart';

/// SQLite-backed [AtKeyValueStore] — the main keystore (`at_data` table).
///
/// Mirrors the Hive keystore's semantics (metadata-builder-on-write,
/// commit-op selection, TTL/TTB visibility, skipCommit purge) while
/// answering expiry / availability from indexed columns rather than an
/// in-memory cache, and lighting up the SQL-only capabilities
/// (`supportsSnapshots` / `supportsPathQueries` / true transactions).
class SqliteAtKeyValueStore
    implements AtKeyValueStore<String, AtData, AtMetaData?> {
  final SqliteDatabase _db;

  /// The atSign owning this store — the `createdBy`/`updatedBy` audit
  /// value the metadata builder stamps.
  final String atSign;

  AtCommitLog? _commitLog;

  final StreamController<KeyStoreChange> _changes =
      StreamController<KeyStoreChange>.broadcast();

  @override
  final List<Future<void> Function(String key, {required bool skipCommit})>
      preRemoveHooks = [];
  @override
  final List<Future<void> Function(String key, {required bool skipCommit})>
      postRemoveHooks = [];

  static const int maxKeyLength = 255;
  static const int maxKeyLengthWithoutCached = 248;

  SqliteAtKeyValueStore(this._db, this.atSign);

  @override
  Future<void> initialize() async {
    // The database is opened and schema-applied by the factory; nothing
    // to do here.
  }

  @override
  AtCommitLog? get commitLog => _commitLog;
  @override
  set commitLog(AtCommitLog? log) => _commitLog = log;

  SqliteAtCommitLog? get _sqliteCommitLog {
    final cl = _commitLog;
    return cl is SqliteAtCommitLog ? cl : null;
  }

  // ---------------------------------------------------------------
  // Single-key reads / writes
  // ---------------------------------------------------------------

  @override
  Future<AtData?> get(String key) async {
    final k = _normalize(key);
    final rows = _db.raw
        .select('SELECT value, metadata FROM at_data WHERE atkey = ?;', [k]);
    if (rows.isEmpty) {
      throw KeyNotFoundException('$key does not exist in keystore');
    }
    return _atDataFromRow(rows.first, k);
  }

  @override
  Future<int?> put(String key, AtData value, {bool skipCommit = false}) async {
    final k = _validateAndNormalize(key);
    if (!_existsSync(k)) {
      return create(key, value, skipCommit: skipCommit);
    }
    final existing = _getSync(k);
    final toStore = AtData()
      ..data = value.data
      ..metaData = AtMetadataBuilder(
        atSign: atSign,
        newAtMetaData: value.metaData,
        existingMetaData: existing?.metaData,
      ).build();
    final result = _db.runInTransaction(() {
      _upsertAtData(k, toStore);
      return skipCommit ? -1 : _commitOrNull(k, CommitOp.UPDATE_ALL);
    });
    _changes.add(KeyUpdated(k));
    return result;
  }

  @override
  Future<int?> create(String key, AtData value,
      {bool skipCommit = false}) async {
    final k = _validateAndNormalize(key);
    _checkMaxLength(k);
    final toStore = AtData()
      ..data = value.data
      ..metaData =
          AtMetadataBuilder(atSign: atSign, newAtMetaData: value.metaData)
              .build();
    final commitOp = _commitOpForNewWrite(value.metaData);
    final result = _db.runInTransaction(() {
      _upsertAtData(k, toStore);
      return skipCommit ? -1 : _commitOrNull(k, commitOp);
    });
    _changes.add(KeyAdded(k));
    return result;
  }

  @override
  Future<int?> putAll(String key, AtData value, AtMetaData? metadata) async {
    final k = _validateAndNormalize(key);
    final existing = _existsSync(k) ? _getSync(k) : null;
    final toStore = AtData()
      ..data = value.data
      ..metaData = AtMetadataBuilder(
        atSign: atSign,
        newAtMetaData: metadata,
        existingMetaData: existing?.metaData,
      ).build();
    final result = _db.runInTransaction(() {
      _upsertAtData(k, toStore);
      return _commitOrNull(k, CommitOp.UPDATE_ALL);
    });
    _changes.add(existing == null ? KeyAdded(k) : KeyUpdated(k));
    return result;
  }

  @override
  Future<int?> putMeta(String key, AtMetaData? metadata) async {
    final k = _validateAndNormalize(key);
    final existing = _existsSync(k) ? _getSync(k)! : AtData();
    final toStore = AtData()
      ..data = existing.data
      ..metaData = AtMetadataBuilder(
        atSign: atSign,
        newAtMetaData: metadata,
        existingMetaData: existing.metaData,
      ).build();
    final result = _db.runInTransaction(() {
      _upsertAtData(k, toStore);
      return _commitOrNull(k, CommitOp.UPDATE_META);
    });
    _changes.add(KeyUpdated(k));
    return result;
  }

  @override
  Future<AtMetaData?> getMeta(String key) async {
    try {
      return (await get(key))?.metaData;
    } on KeyNotFoundException {
      return null;
    }
  }

  @override
  Future<void> restore(String key, AtData value) async {
    final k = _validateAndNormalize(key);
    _checkMaxLength(k);
    // Verbatim: store value as-is (its own metadata), no builder pass,
    // no commit-log append, no change event.
    _db.runInTransaction(() => _upsertAtData(k, value));
  }

  @override
  Future<int?> remove(String key, {bool skipCommit = false}) async {
    final lowered = key.toLowerCase();
    for (final hook in preRemoveHooks) {
      await hook(lowered, skipCommit: skipCommit);
    }
    final k = _normalize(key);
    final result = _db.runInTransaction(() {
      _db.raw.execute('DELETE FROM at_data WHERE atkey = ?;', [k]);
      if (skipCommit) {
        _sqliteCommitLog?.purgeSync(k);
        return -1;
      }
      return _commitOrNull(k, CommitOp.DELETE);
    });
    _changes.add(KeyRemoved(k));
    for (final hook in postRemoveHooks) {
      await hook(lowered, skipCommit: skipCommit);
    }
    return result;
  }

  @override
  Future<int> removeMany(List<String> keys, {bool skipCommit = false}) async {
    final normalized = keys.map(_normalize).toSet().toList();
    var removed = 0;
    final toFire = <String>[];
    _db.runInTransaction(() {
      for (final k in normalized) {
        if (!_existsSync(k)) continue;
        _db.raw.execute('DELETE FROM at_data WHERE atkey = ?;', [k]);
        if (skipCommit) {
          _sqliteCommitLog?.purgeSync(k);
        } else {
          _commitOrNull(k, CommitOp.DELETE);
        }
        removed++;
        toFire.add(k);
      }
    });
    for (final k in toFire) {
      _changes.add(KeyRemoved(k));
    }
    return removed;
  }

  @override
  Future<Map<String, AtData>> getMany(List<String> keys) async {
    if (keys.isEmpty) return {};
    final normalized = keys.map(_normalize).toList();
    final placeholders = List.filled(normalized.length, '?').join(',');
    final rows = _db.raw.select(
        'SELECT atkey, value, metadata FROM at_data WHERE atkey IN ($placeholders);',
        normalized);
    final result = <String, AtData>{};
    for (final row in rows) {
      final atkey = row['atkey'] as String;
      result[atkey] = _atDataFromRow(row, atkey);
    }
    return result;
  }

  @override
  Future<bool> exists(String key) async => _existsSync(_normalize(key));

  // ---------------------------------------------------------------
  // Expiry / availability
  // ---------------------------------------------------------------

  @override
  Future<Stream<String>> getExpiredKeys() async {
    final now = _nowMillis();
    final rows = _db.raw.select(
        'SELECT atkey FROM at_data WHERE expires_at IS NOT NULL AND expires_at <= ?;',
        [now]);
    return Stream.fromIterable(rows.map((r) => r['atkey'] as String));
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    final expired =
        (await getExpiredKeys()).asBroadcastStream(); // materialize below
    final keys = <String>[];
    await for (final k in expired) {
      keys.add(k);
    }
    for (final k in keys) {
      // Expiry deletes are local-only maintenance: purge the row and its
      // commit entry, never advance the commit id.
      await remove(k, skipCommit: true);
    }
    return true;
  }

  @override
  Future<DateTime?> nextExpiresAt() async {
    final v = _db.raw
        .select(
            'SELECT MIN(expires_at) m FROM at_data WHERE expires_at IS NOT NULL;')
        .first['m'];
    return v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(v as int, isUtc: true);
  }

  @override
  Future<Stream<String>> peekExpired({DateTime? asOf, int? limit}) async {
    final cutoff = (asOf ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    var sql =
        'SELECT atkey FROM at_data WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at';
    final params = <Object?>[cutoff];
    if (limit != null) {
      sql += ' LIMIT ?';
      params.add(limit);
    }
    final rows = _db.raw.select('$sql;', params);
    return Stream.fromIterable(rows.map((r) => r['atkey'] as String));
  }

  @override
  Future<DateTime?> nextAvailableAt({DateTime? asOf}) async {
    final now = (asOf ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final v = _db.raw.select(
        'SELECT MIN(available_at) m FROM at_data WHERE available_at IS NOT NULL AND available_at > ?;',
        [now]).first['m'];
    return v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(v as int, isUtc: true);
  }

  @override
  Future<Stream<String>> peekNewlyAvailable({
    required DateTime since,
    DateTime? asOf,
    int? limit,
  }) async {
    final lo = since.toUtc().millisecondsSinceEpoch;
    final hi = (asOf ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    var sql =
        'SELECT atkey FROM at_data WHERE available_at IS NOT NULL AND available_at > ? AND available_at <= ? ORDER BY available_at';
    final params = <Object?>[lo, hi];
    if (limit != null) {
      sql += ' LIMIT ?';
      params.add(limit);
    }
    final rows = _db.raw.select('$sql;', params);
    return Stream.fromIterable(rows.map((r) => r['atkey'] as String));
  }

  // ---------------------------------------------------------------
  // Listing
  // ---------------------------------------------------------------

  @override
  Future<Stream<String>> getKeys({String? regex}) async {
    // Eager validation: a bad regex rejects the Future, not the Stream.
    final re = RegExp(regex ?? '.*');
    final now = _nowMillis();
    final rows = _db.raw.select(
        'SELECT atkey FROM at_data WHERE (available_at IS NULL OR available_at <= ?) '
        'AND (expires_at IS NULL OR expires_at > ?);',
        [now, now]);
    final matched =
        rows.map((r) => r['atkey'] as String).where(re.hasMatch).toList();
    return Stream.fromIterable(matched);
  }

  @override
  Future<Stream<String>> scanKeys(
    KeyPattern pattern, {
    bool includeExpired = false,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  }) async {
    var where = '1=1';
    final params = <Object?>[];
    if (!includeExpired) {
      final now = _nowMillis();
      where +=
          ' AND (available_at IS NULL OR available_at <= ?) AND (expires_at IS NULL OR expires_at > ?)';
      params
        ..add(now)
        ..add(now);
    }
    final order = switch (orderBy) {
      OrderByKey.byKey => ' ORDER BY atkey',
      OrderByKey.byExpiresAt =>
        ' ORDER BY (expires_at IS NULL), expires_at', // nulls last
      OrderByKey.byCreatedAt =>
        " ORDER BY json_extract(metadata, '\$.createdAt')",
      null => '',
    };
    final rows =
        _db.raw.select('SELECT atkey FROM at_data WHERE $where$order;', params);
    // KeyPattern filter, then skip/limit (limit is post-filter, matching
    // the Hive semantics).
    var matched = rows
        .map((r) => r['atkey'] as String)
        .where((k) => SqliteQueryTranslator.matchesKeyPattern(k, pattern));
    if (skip != null) matched = matched.skip(skip);
    if (limit != null) matched = matched.take(limit);
    return Stream.fromIterable(matched.toList());
  }

  // ---------------------------------------------------------------
  // Reactive / transactional / diagnostic
  // ---------------------------------------------------------------

  @override
  Stream<KeyStoreChange> get changes => _changes.stream;

  @override
  Future<R> transaction<R>(
      Future<R> Function(KeyStoreTxn<String, AtData, dynamic> txn) body) async {
    final txn = _SqliteKeyStoreTxn(this);
    final result = await body(txn);
    // Apply buffered ops atomically, in body order.
    final fired = <KeyStoreChange>[];
    _db.runInTransaction(() {
      for (final op in txn._ops) {
        if (op.isRemove) {
          if (_existsSync(op.key)) {
            _db.raw.execute('DELETE FROM at_data WHERE atkey = ?;', [op.key]);
            _commitOrNull(op.key, CommitOp.DELETE);
            fired.add(KeyRemoved(op.key));
          }
        } else {
          final existed = _existsSync(op.key);
          final toStore = AtData()
            ..data = op.value!.data
            ..metaData = AtMetadataBuilder(
              atSign: atSign,
              newAtMetaData: op.metadata,
              existingMetaData: existed ? _getSync(op.key)?.metaData : null,
            ).build();
          _upsertAtData(op.key, toStore);
          _commitOrNull(op.key, CommitOp.UPDATE_ALL);
          fired.add(existed ? KeyUpdated(op.key) : KeyAdded(op.key));
        }
      }
    });
    for (final change in fired) {
      _changes.add(change);
    }
    return result;
  }

  @override
  bool get supportsSnapshots => false;

  @override
  Future<AtKeyValueStoreSnapshot<String, AtData, AtMetaData?>>
      snapshot() async {
    return _SqliteSnapshot.open(_db.path);
  }

  @override
  bool get supportsPathQueries => true;

  @override
  Stream<KeyEntry<String, AtData, AtMetaData?>> queryByPath({
    required KeyPattern keyPattern,
    required Predicate predicate,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  }) async* {
    final translated = SqliteQueryTranslator.predicateToSql(predicate, 'value');
    final where = '(${translated.sql})';
    final params = <Object?>[...translated.params];
    final order = switch (orderBy) {
      OrderByKey.byKey => ' ORDER BY atkey',
      OrderByKey.byExpiresAt => ' ORDER BY (expires_at IS NULL), expires_at',
      OrderByKey.byCreatedAt =>
        " ORDER BY json_extract(metadata, '\$.createdAt')",
      null => '',
    };
    final rows = _db.raw.select(
        'SELECT atkey, value, metadata FROM at_data WHERE $where$order;',
        params);
    var entries = rows
        .where((r) => SqliteQueryTranslator.matchesKeyPattern(
            r['atkey'] as String, keyPattern))
        .map((r) {
      final atkey = r['atkey'] as String;
      final atData = _atDataFromRow(r, atkey);
      return KeyEntry<String, AtData, AtMetaData?>(
          atkey, atData, atData.metaData);
    });
    if (skip != null) entries = entries.skip(skip);
    if (limit != null) entries = entries.take(limit);
    for (final e in entries) {
      yield e;
    }
  }

  @override
  Future<KeyStoreStats> stats() async {
    final row = _db.raw
        .select('SELECT '
            'COUNT(*) total, '
            'SUM(CASE WHEN expires_at IS NOT NULL THEN 1 ELSE 0 END) ttl, '
            'SUM(CASE WHEN available_at IS NOT NULL THEN 1 ELSE 0 END) ttb, '
            "MIN(json_extract(metadata, '\$.createdAt')) oldest, "
            "MAX(json_extract(metadata, '\$.createdAt')) newest "
            'FROM at_data;')
        .first;
    DateTime? parse(Object? v) =>
        v == null ? null : DateTime.tryParse(v as String);
    return KeyStoreStats(
      totalKeys: (row['total'] as int?) ?? 0,
      ttlKeys: (row['ttl'] as int?) ?? 0,
      ttbKeys: (row['ttb'] as int?) ?? 0,
      sizeBytes:
          _db.raw.select('PRAGMA page_count;').first.values.first as int? ?? 0,
      oldestCreatedAt: parse(row['oldest']),
      newestCreatedAt: parse(row['newest']),
    );
  }

  @override
  Stream<Object> compact(bool dryRun) =>
      _commitLog?.compact(dryRun) ?? const Stream.empty();

  /// Drops all rows (keeping the connection open) for test isolation.
  Future<void> clear() async {
    _db.raw.execute('DELETE FROM at_data;');
  }

  /// No-op: the shared connection is closed by the bundle.
  Future<void> close() async {}

  // ---------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------

  String _normalize(String key) => key.trim().toLowerCase().replaceAll(' ', '');

  String _validateAndNormalize(String key) {
    final normalized = _normalize(key);
    if (AtKey.getKeyType(normalized, enforceNameSpace: false) ==
        KeyType.invalidKey) {
      throw InvalidAtKeyException('Key $key is invalid');
    }
    return normalized;
  }

  void _checkMaxLength(String key) {
    final maxLength =
        key.startsWith('cached:') ? maxKeyLength : maxKeyLengthWithoutCached;
    if (key.length > maxLength) {
      throw DataStoreException(
          'key length ${key.length} is greater than max allowed $maxLength chars');
    }
  }

  int _nowMillis() => DateTime.now().toUtc().millisecondsSinceEpoch;

  bool _existsSync(String normalizedKey) => _db.raw.select(
      'SELECT 1 FROM at_data WHERE atkey = ? LIMIT 1;',
      [normalizedKey]).isNotEmpty;

  AtData? _getSync(String normalizedKey) {
    final rows = _db.raw.select(
        'SELECT value, metadata FROM at_data WHERE atkey = ?;',
        [normalizedKey]);
    return rows.isEmpty ? null : _atDataFromRow(rows.first, normalizedKey);
  }

  void _upsertAtData(String atkey, AtData data) {
    final m = data.metaData ?? AtMetaData();
    _db.raw.execute(
      'INSERT INTO at_data (atkey, value, metadata, expires_at, available_at, refresh_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(atkey) DO UPDATE SET value = excluded.value, '
      'metadata = excluded.metadata, expires_at = excluded.expires_at, '
      'available_at = excluded.available_at, refresh_at = excluded.refresh_at;',
      [
        atkey,
        data.data,
        SqliteMetadataCodec.encode(m),
        SqliteMetadataCodec.expiresAtMillis(m),
        SqliteMetadataCodec.availableAtMillis(m),
        SqliteMetadataCodec.refreshAtMillis(m),
      ],
    );
  }

  int? _commitOrNull(String atkey, CommitOp op) =>
      _sqliteCommitLog?.commitSync(atkey, op);

  AtData _atDataFromRow(Row row, String atkey) => AtData()
    ..data = row['value'] as String?
    ..metaData = SqliteMetadataCodec.decode(row['metadata'] as String)
    ..key = atkey;

  /// Sets [CommitOp.UPDATE_ALL] when any metadata field is present (a
  /// value+metadata write), else [CommitOp.UPDATE]. Mirrors the Hive
  /// create path's null-check chain.
  CommitOp _commitOpForNewWrite(AtMetaData? m) {
    if (m != null &&
        (m.ttl != null ||
            m.ttb != null ||
            m.ttr != null ||
            m.isCascade != null ||
            m.isBinary != null ||
            m.isEncrypted != null ||
            m.dataSignature != null ||
            m.sharedKeyEnc != null ||
            m.pubKeyCS != null ||
            m.encoding != null ||
            m.encKeyName != null ||
            m.encAlgo != null ||
            m.ivNonce != null ||
            m.skeEncKeyName != null ||
            m.skeEncAlgo != null ||
            m.pubKeyHash != null ||
            m.immutable != null)) {
      return CommitOp.UPDATE_ALL;
    }
    return CommitOp.UPDATE;
  }
}

/// Buffered transaction handle — reads see buffered writes over live
/// state; buffered ops are applied atomically by
/// [SqliteAtKeyValueStore.transaction].
class _SqliteKeyStoreTxn implements KeyStoreTxn<String, AtData, dynamic> {
  final SqliteAtKeyValueStore _store;
  final List<_BufferedOp> _ops = [];

  _SqliteKeyStoreTxn(this._store);

  @override
  Future<void> put(String key, AtData value, dynamic metadata) async {
    _ops.add(_BufferedOp.put(
        _store._normalize(key), value, metadata as AtMetaData?));
  }

  @override
  Future<void> remove(String key) async {
    _ops.add(_BufferedOp.remove(_store._normalize(key)));
  }

  @override
  Future<AtData?> get(String key) async {
    final k = _store._normalize(key);
    // Last buffered op for this key wins over live state.
    for (final op in _ops.reversed) {
      if (op.key == k) {
        return op.isRemove ? null : op.value;
      }
    }
    return _store._getSync(k);
  }

  @override
  Future<bool> exists(String key) async => (await get(key)) != null;
}

class _BufferedOp {
  final String key;
  final bool isRemove;
  final AtData? value;
  final AtMetaData? metadata;

  _BufferedOp.put(this.key, this.value, this.metadata) : isRemove = false;
  _BufferedOp.remove(this.key)
      : isRemove = true,
        value = null,
        metadata = null;
}

/// A live-reading snapshot: `supportsSnapshots` is false, so reads reflect
/// live state (just like Hive best-effort snapshots).
class _SqliteSnapshot
    implements AtKeyValueStoreSnapshot<String, AtData, AtMetaData?> {
  final Database _conn;
  bool _released = false;

  _SqliteSnapshot._(this._conn);

  static _SqliteSnapshot open(String path) {
    final conn = sqlite3.open(path);
    return _SqliteSnapshot._(conn);
  }

  @override
  Future<AtData?> get(String key) async {
    final k = key.trim().toLowerCase().replaceAll(' ', '');
    final rows = _conn
        .select('SELECT value, metadata FROM at_data WHERE atkey = ?;', [k]);
    if (rows.isEmpty) return null;
    return AtData()
      ..data = rows.first['value'] as String?
      ..metaData = SqliteMetadataCodec.decode(rows.first['metadata'] as String)
      ..key = k;
  }

  @override
  Stream<String> scanKeys(KeyPattern pattern) async* {
    final rows = _conn.select('SELECT atkey FROM at_data;');
    for (final r in rows) {
      final k = r['atkey'] as String;
      if (SqliteQueryTranslator.matchesKeyPattern(k, pattern)) yield k;
    }
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _conn.dispose();
  }
}
