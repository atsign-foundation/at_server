import 'dart:async';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

import 'sqlite_database.dart';
import 'sqlite_notification_codec.dart';

/// SQLite-backed [AtNotificationKeystore] (`notifications` table). A
/// `KeyValueStore<String, AtNotification>` — no commit log, no metadata
/// triplet — plus the notification-specific `init` / `iterate` surface.
class SqliteAtNotificationKeystore
    implements AtNotificationKeystore {
  final SqliteDatabase _db;

  final StreamController<KeyStoreChange> _changes =
      StreamController<KeyStoreChange>.broadcast();

  @override
  final List<Future<void> Function(String key, {required bool skipCommit})>
      preRemoveHooks = [];
  @override
  final List<Future<void> Function(String key, {required bool skipCommit})>
      postRemoveHooks = [];

  SqliteAtNotificationKeystore(this._db);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> init(String path) async {
    // The shared database is opened by the factory; nothing to do.
  }

  @override
  Future<int?> put(String key, AtNotification value,
      {bool skipCommit = false}) async {
    final existed = await exists(key);
    _db.runInTransaction(() {
      _db.raw.execute(
        'INSERT INTO notifications (id, payload, notification_datetime, type, status, expires_at) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, '
        'notification_datetime = excluded.notification_datetime, '
        'type = excluded.type, status = excluded.status, '
        'expires_at = excluded.expires_at;',
        [
          key,
          SqliteNotificationCodec.encode(value),
          SqliteNotificationCodec.notificationDateTimeMillis(value) ?? 0,
          SqliteNotificationCodec.typeExtract(value),
          SqliteNotificationCodec.statusExtract(value),
          SqliteNotificationCodec.expiresAtMillis(value),
        ],
      );
    });
    _changes.add(existed ? KeyUpdated(key) : KeyAdded(key));
    return null; // notifications carry no commit id
  }

  @override
  Future<int?> create(String key, AtNotification value,
          {bool skipCommit = false}) =>
      put(key, value, skipCommit: skipCommit);

  @override
  Future<AtNotification?> get(String key) async {
    final rows =
        _db.raw.select('SELECT payload FROM notifications WHERE id = ?;', [key]);
    if (rows.isEmpty) return null;
    return SqliteNotificationCodec.decode(rows.first['payload'] as String);
  }

  @override
  Future<int?> remove(String key, {bool skipCommit = false}) async {
    for (final hook in preRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }
    _db.raw.execute('DELETE FROM notifications WHERE id = ?;', [key]);
    _changes.add(KeyRemoved(key));
    for (final hook in postRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }
    return null;
  }

  @override
  Future<bool> exists(String key) async => _db.raw
      .select('SELECT 1 FROM notifications WHERE id = ? LIMIT 1;', [key])
      .isNotEmpty;

  @override
  Future<Map<String, AtNotification>> getMany(List<String> keys) async {
    final result = <String, AtNotification>{};
    for (final k in keys) {
      final n = await get(k);
      if (n != null) result[k] = n;
    }
    return result;
  }

  @override
  Future<int> removeMany(List<String> keys, {bool skipCommit = false}) async {
    var removed = 0;
    _db.runInTransaction(() {
      for (final k in keys) {
        if (_db.raw
            .select('SELECT 1 FROM notifications WHERE id = ? LIMIT 1;', [k])
            .isEmpty) {
          continue;
        }
        _db.raw.execute('DELETE FROM notifications WHERE id = ?;', [k]);
        removed++;
      }
    });
    return removed;
  }

  @override
  Future<Stream<String>> getKeys({String? regex}) async {
    final re = RegExp(regex ?? '.*');
    final rows = _db.raw.select('SELECT id FROM notifications;');
    return Stream.fromIterable(
        rows.map((r) => r['id'] as String).where(re.hasMatch));
  }

  @override
  Future<Stream<String>> getExpiredKeys() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final maxTtlMillis = AtNotification.maxTtl.inMilliseconds;
    final rows = _db.raw.select(
        "SELECT id FROM notifications WHERE status = 'expired' "
        'OR (expires_at IS NOT NULL AND expires_at <= ?) '
        'OR notification_datetime <= ?;',
        [now, now - maxTtlMillis]);
    return Stream.fromIterable(rows.map((r) => r['id'] as String));
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    final keys = await (await getExpiredKeys()).toList();
    for (final k in keys) {
      await remove(k, skipCommit: true);
    }
    return true;
  }

  @override
  Future<DateTime?> nextExpiresAt() async {
    final v = _db.raw
        .select(
            'SELECT MIN(expires_at) m FROM notifications WHERE expires_at IS NOT NULL;')
        .first['m'];
    return v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(v as int, isUtc: true);
  }

  @override
  Future<Stream<String>> peekExpired({DateTime? asOf, int? limit}) async {
    final cutoff = (asOf ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    var sql =
        'SELECT id FROM notifications WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at';
    final params = <Object?>[cutoff];
    if (limit != null) {
      sql += ' LIMIT ?';
      params.add(limit);
    }
    final rows = _db.raw.select('$sql;', params);
    return Stream.fromIterable(rows.map((r) => r['id'] as String));
  }

  @override
  Stream<KeyStoreChange> get changes => _changes.stream;

  @override
  Future<R> transaction<R>(
      Future<R> Function(KeyStoreTxn<String, AtNotification, dynamic> txn)
          body) async {
    // Notifications are appended one-at-a-time in practice; a minimal
    // buffered transaction keeps the contract without a bespoke handle.
    throw UnsupportedError(
        'transaction() is not used on the notification keystore');
  }

  @override
  bool get supportsSnapshots => false;

  @override
  Future<KeyStoreSnapshot<String, AtNotification, dynamic>> snapshot() async {
    return _LiveNotificationSnapshot(this);
  }

  @override
  Future<KeyStoreStats> stats() async {
    final total =
        _db.raw.select('SELECT COUNT(*) c FROM notifications;').first['c']
            as int;
    return KeyStoreStats(
      totalKeys: total,
      ttlKeys: 0,
      ttbKeys: 0,
      sizeBytes: 0,
      oldestCreatedAt: null,
      newestCreatedAt: null,
    );
  }

  @override
  Stream<AtNotification> iterate() async* {
    final rows =
        _db.raw.select('SELECT payload FROM notifications ORDER BY id;');
    for (final r in rows) {
      yield SqliteNotificationCodec.decode(r['payload'] as String);
    }
  }

  @override
  int entriesCount() =>
      _db.raw.select('SELECT COUNT(*) c FROM notifications;').first['c'] as int;

  @override
  int getSize() {
    final pageCount =
        _db.raw.select('PRAGMA page_count;').first.values.first as int? ?? 0;
    final pageSize =
        _db.raw.select('PRAGMA page_size;').first.values.first as int? ?? 0;
    return pageCount * pageSize;
  }

  @override
  Future<void> close() async {}

  /// Drops all rows (keeping the connection open) for test isolation.
  Future<void> clear() async {
    _db.raw.execute('DELETE FROM notifications;');
  }

  @override
  Stream<String> compact(bool dryRun) async* {
    final expired = await (await getExpiredKeys()).toList();
    if (dryRun) {
      yield* Stream.fromIterable(expired);
      return;
    }
    for (final id in expired) {
      await remove(id, skipCommit: true);
      yield id;
    }
  }
}

/// A live-reading snapshot: `supportsSnapshots` is false, so reads reflect
/// current state (parity with the Hive notification keystore).
class _LiveNotificationSnapshot
    implements KeyStoreSnapshot<String, AtNotification, dynamic> {
  final SqliteAtNotificationKeystore _store;
  _LiveNotificationSnapshot(this._store);

  @override
  Future<AtNotification?> get(String key) => _store.get(key);

  @override
  Future<void> release() async {}
}
