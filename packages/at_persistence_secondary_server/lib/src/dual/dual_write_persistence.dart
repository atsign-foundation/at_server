import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// A persistence layer that serves all reads from a **primary** backend while
/// mirroring every write into a **secondary** backend, so a real workload
/// (e.g. the functional pack) can be run once and the two resulting DB sets
/// compared for logical identity afterwards.
///
/// The mirror is byte-exact, not operation-replayed: each write is applied to
/// the primary, then the primary's resulting per-key state (data + metadata
/// with its server-stamped createdAt/updatedAt, and its commit entry with its
/// commit id) is copied verbatim into the secondary via `restore` / `replay`.
/// Replaying the *operation* on the secondary instead would let each backend
/// stamp its own timestamps and diverge.
///
/// Reads, capability flags, snapshots, and change events all come from the
/// primary, so the server behaves exactly as if it were running on the
/// primary backend alone.

class DualWritePersistenceConfig implements AtPersistenceConfig {
  final AtPersistenceConfig primary;
  final AtPersistenceConfig secondary;

  DualWritePersistenceConfig({required this.primary, required this.secondary});

  @override
  AtPersistenceBackendId get backend => primary.backend;
  @override
  String get storagePath => primary.storagePath;
  @override
  String get commitLogPath => primary.commitLogPath;
  @override
  String get accessLogPath => primary.accessLogPath;
  @override
  String get notificationStoragePath => primary.notificationStoragePath;
  @override
  String get backendMarkerPath => primary.backendMarkerPath;
  @override
  bool get enableAccessLog => primary.enableAccessLog;
  @override
  bool get enableNotificationKeystore => primary.enableNotificationKeystore;
  @override
  bool get enableCommitLog => primary.enableCommitLog;
}

class DualWriteAtPersistenceFactory implements AtPersistenceFactory {
  final AtPersistenceFactory primaryFactory;
  final AtPersistenceFactory secondaryFactory;

  final Map<String, DualWriteBundle> _bundles = {};

  DualWriteAtPersistenceFactory(this.primaryFactory, this.secondaryFactory);

  @override
  AtPersistenceBackendId get backendId => primaryFactory.backendId;

  @override
  Future<AtPersistenceBundle> initialize(
      String atSign, AtPersistenceConfig config) async {
    if (config is! DualWritePersistenceConfig) {
      throw ArgumentError('DualWriteAtPersistenceFactory expects '
          'DualWritePersistenceConfig, got ${config.runtimeType}');
    }
    final existing = _bundles[atSign];
    if (existing != null && !existing.isClosed) return existing;

    final primary = await primaryFactory.initialize(atSign, config.primary);
    final secondary =
        await secondaryFactory.initialize(atSign, config.secondary);
    final bundle = DualWriteBundle._(atSign, primary, secondary);
    _bundles[atSign] = bundle;
    return bundle;
  }

  @override
  AtPersistenceBundle? bundleFor(String atSign) {
    final b = _bundles[atSign];
    return (b == null || b.isClosed) ? null : b;
  }

  @override
  Future<void> closeFor(String atSign) async {
    await _bundles.remove(atSign)?.close();
  }

  @override
  Future<void> close() async {
    for (final b in _bundles.values.toList()) {
      await b.close();
    }
    _bundles.clear();
    await primaryFactory.close();
    await secondaryFactory.close();
  }
}

class DualWriteBundle implements AtPersistenceBundle {
  @override
  final String atSign;

  final AtPersistenceBundle primary;
  final AtPersistenceBundle secondary;

  @override
  late final AtKeyValueStore<String, AtData, AtMetaData?> keyValueStore;
  @override
  late final AtAccessLog? accessLog;
  @override
  late final AtNotificationKeystore? notificationKeystore;

  bool _closed = false;

  DualWriteBundle._(this.atSign, this.primary, this.secondary) {
    keyValueStore =
        _DualWriteKeyStore(primary.keyValueStore, secondary.keyValueStore);
    accessLog = (primary.accessLog != null && secondary.accessLog != null)
        ? _DualWriteAccessLog(primary.accessLog!, secondary.accessLog!)
        : primary.accessLog;
    notificationKeystore = (primary.notificationKeystore != null &&
            secondary.notificationKeystore != null)
        ? _DualWriteNotificationKeystore(
            primary.notificationKeystore!, secondary.notificationKeystore!)
        : primary.notificationKeystore;
  }

  @override
  AtPersistenceBackendId get backendId => primary.backendId;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> clear() async {
    await primary.clear();
    await secondary.clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await primary.close();
    await secondary.close();
  }
}

/// Keystore wrapper: writes to primary, then mirrors the affected key's exact
/// resulting state into secondary. Reads/capabilities delegate to primary.
class _DualWriteKeyStore implements AtKeyValueStore<String, AtData, AtMetaData?> {
  final AtKeyValueStore<String, AtData, AtMetaData?> _primary;
  final AtKeyValueStore<String, AtData, AtMetaData?> _secondary;

  _DualWriteKeyStore(this._primary, this._secondary);

  Future<AtData?> _tryGet(
      AtKeyValueStore<String, AtData, AtMetaData?> ks, String key) async {
    try {
      return await ks.get(key);
    } on KeyNotFoundException {
      return null;
    }
  }

  /// Makes secondary's state for [key] identical to primary's: same row
  /// (data + metadata) and same commit entry (id, op, opTime), or same
  /// absence.
  Future<void> _mirror(String key) async {
    final data = await _tryGet(_primary, key);
    if (data != null) {
      await _secondary.restore(key, data);
    } else {
      // Absent in primary → delete the row and purge any commit entry.
      await _secondary.remove(key, skipCommit: true);
    }
    final entry = _primary.commitLog?.getLatestCommitEntry(key);
    if (entry != null) {
      await _secondary.commitLog?.replay(entry);
    }
  }

  @override
  Future<int?> put(String key, AtData value, {bool skipCommit = false}) async {
    final id = await _primary.put(key, value, skipCommit: skipCommit);
    await _mirror(key);
    return id;
  }

  @override
  Future<int?> create(String key, AtData value,
      {bool skipCommit = false}) async {
    final id = await _primary.create(key, value, skipCommit: skipCommit);
    await _mirror(key);
    return id;
  }

  @override
  Future<int?> putAll(String key, AtData value, AtMetaData? metadata) async {
    final id = await _primary.putAll(key, value, metadata);
    await _mirror(key);
    return id;
  }

  @override
  Future<int?> putMeta(String key, AtMetaData? metadata) async {
    final id = await _primary.putMeta(key, metadata);
    await _mirror(key);
    return id;
  }

  @override
  Future<void> restore(String key, AtData value) async {
    await _primary.restore(key, value);
    await _mirror(key);
  }

  @override
  Future<int?> remove(String key, {bool skipCommit = false}) async {
    final id = await _primary.remove(key, skipCommit: skipCommit);
    await _mirror(key);
    return id;
  }

  @override
  Future<int> removeMany(List<String> keys, {bool skipCommit = false}) async {
    final n = await _primary.removeMany(keys, skipCommit: skipCommit);
    for (final k in keys) {
      await _mirror(k);
    }
    return n;
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    final expired = await (await _primary.getExpiredKeys()).toList();
    final result = await _primary.deleteExpiredKeys();
    for (final k in expired) {
      await _mirror(k);
    }
    return result;
  }

  // ---- reads / capabilities: primary ----
  @override
  Future<void> initialize() => _primary.initialize();
  @override
  AtCommitLog? get commitLog => _primary.commitLog;
  @override
  set commitLog(AtCommitLog? log) => _primary.commitLog = log;
  @override
  Future<AtData?> get(String key) => _primary.get(key);
  @override
  Future<AtMetaData?> getMeta(String key) => _primary.getMeta(key);
  @override
  Future<Map<String, AtData>> getMany(List<String> keys) =>
      _primary.getMany(keys);
  @override
  Future<bool> exists(String key) => _primary.exists(key);
  @override
  Future<Stream<String>> getKeys({String? regex}) =>
      _primary.getKeys(regex: regex);
  @override
  Future<Stream<String>> getExpiredKeys() => _primary.getExpiredKeys();
  @override
  Future<DateTime?> nextExpiresAt() => _primary.nextExpiresAt();
  @override
  Future<Stream<String>> peekExpired({DateTime? asOf, int? limit}) =>
      _primary.peekExpired(asOf: asOf, limit: limit);
  @override
  Future<DateTime?> nextAvailableAt({DateTime? asOf}) =>
      _primary.nextAvailableAt(asOf: asOf);
  @override
  Future<Stream<String>> peekNewlyAvailable(
          {required DateTime since, DateTime? asOf, int? limit}) =>
      _primary.peekNewlyAvailable(since: since, asOf: asOf, limit: limit);
  @override
  Future<Stream<String>> scanKeys(KeyPattern pattern,
          {bool includeExpired = false,
          OrderByKey? orderBy,
          int? limit,
          int? skip}) =>
      _primary.scanKeys(pattern,
          includeExpired: includeExpired,
          orderBy: orderBy,
          limit: limit,
          skip: skip);
  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      get preRemoveHooks => _primary.preRemoveHooks;
  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      get postRemoveHooks => _primary.postRemoveHooks;
  @override
  Stream<KeyStoreChange> get changes => _primary.changes;
  @override
  bool get supportsSnapshots => _primary.supportsSnapshots;
  @override
  Future<AtKeyValueStoreSnapshot<String, AtData, AtMetaData?>> snapshot() =>
      _primary.snapshot();
  @override
  bool get supportsPathQueries => _primary.supportsPathQueries;
  @override
  Stream<KeyEntry<String, AtData, AtMetaData?>> queryByPath(
          {required KeyPattern keyPattern,
          required Predicate predicate,
          OrderByKey? orderBy,
          int? limit,
          int? skip}) =>
      _primary.queryByPath(
          keyPattern: keyPattern,
          predicate: predicate,
          orderBy: orderBy,
          limit: limit,
          skip: skip);
  @override
  Future<KeyStoreStats> stats() => _primary.stats();
  @override
  Stream<Object> compact(bool dryRun) => _primary.compact(dryRun);

  @override
  Future<R> transaction<R>(
      Future<R> Function(KeyStoreTxn<String, AtData, dynamic> txn) body) {
    // Server verb handlers do not use keystore transactions; delegating to
    // primary (unmirrored) keeps the contract without a bespoke handle.
    return _primary.transaction(body);
  }
}

/// Notification wrapper: notifications carry no server-stamped write-time
/// fields, so a straight tee keeps the two stores identical.
class _DualWriteNotificationKeystore implements AtNotificationKeystore {
  final AtNotificationKeystore _primary;
  final AtNotificationKeystore _secondary;

  _DualWriteNotificationKeystore(this._primary, this._secondary);

  @override
  Future<int?> put(String key, AtNotification value,
      {bool skipCommit = false}) async {
    final id = await _primary.put(key, value, skipCommit: skipCommit);
    await _secondary.put(key, value, skipCommit: skipCommit);
    return id;
  }

  @override
  Future<int?> create(String key, AtNotification value,
          {bool skipCommit = false}) =>
      put(key, value, skipCommit: skipCommit);

  @override
  Future<int?> remove(String key, {bool skipCommit = false}) async {
    final id = await _primary.remove(key, skipCommit: skipCommit);
    await _secondary.remove(key, skipCommit: skipCommit);
    return id;
  }

  @override
  Future<int> removeMany(List<String> keys, {bool skipCommit = false}) async {
    final n = await _primary.removeMany(keys, skipCommit: skipCommit);
    await _secondary.removeMany(keys, skipCommit: skipCommit);
    return n;
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    final expired = await (await _primary.getExpiredKeys()).toList();
    final result = await _primary.deleteExpiredKeys();
    if (expired.isNotEmpty) await _secondary.removeMany(expired, skipCommit: true);
    return result;
  }

  @override
  Future<void> init(String path) async {
    await _primary.init(path);
    await _secondary.init(path);
  }

  @override
  Future<void> initialize() => _primary.initialize();
  @override
  Future<AtNotification?> get(String key) => _primary.get(key);
  @override
  Future<Map<String, AtNotification>> getMany(List<String> keys) =>
      _primary.getMany(keys);
  @override
  Future<bool> exists(String key) => _primary.exists(key);
  @override
  Future<Stream<String>> getKeys({String? regex}) =>
      _primary.getKeys(regex: regex);
  @override
  Future<Stream<String>> getExpiredKeys() => _primary.getExpiredKeys();
  @override
  Future<DateTime?> nextExpiresAt() => _primary.nextExpiresAt();
  @override
  Future<Stream<String>> peekExpired({DateTime? asOf, int? limit}) =>
      _primary.peekExpired(asOf: asOf, limit: limit);
  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      get preRemoveHooks => _primary.preRemoveHooks;
  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      get postRemoveHooks => _primary.postRemoveHooks;
  @override
  Stream<KeyStoreChange> get changes => _primary.changes;
  @override
  bool get supportsSnapshots => _primary.supportsSnapshots;
  @override
  Future<KeyStoreSnapshot<String, AtNotification, dynamic>> snapshot() =>
      _primary.snapshot();
  @override
  Future<KeyStoreStats> stats() => _primary.stats();
  @override
  Future<R> transaction<R>(
          Future<R> Function(KeyStoreTxn<String, AtNotification, dynamic> txn)
              body) =>
      _primary.transaction(body);
  @override
  Stream<AtNotification> iterate() => _primary.iterate();
  @override
  int entriesCount() => _primary.entriesCount();
  @override
  int getSize() => _primary.getSize();
  @override
  Future<void> close() async {
    await _primary.close();
    await _secondary.close();
  }

  @override
  Stream<String> compact(bool dryRun) async* {
    final removed = <String>[];
    await for (final id in _primary.compact(dryRun)) {
      removed.add(id);
      yield id;
    }
    if (!dryRun && removed.isNotEmpty) {
      await _secondary.removeMany(removed, skipCommit: true);
    }
  }
}

/// Access-log wrapper: `insert` stamps `now` per backend, so mirror the exact
/// entry the primary just wrote via `replay`.
class _DualWriteAccessLog implements AtAccessLog {
  final AtAccessLog _primary;
  final AtAccessLog _secondary;

  _DualWriteAccessLog(this._primary, this._secondary);

  @override
  Future<int?> insert(String fromAtSign, String verbName,
      {String? lookupKey}) async {
    // Build the entry once and replay the SAME entry to both logs. Using
    // primary.insert + getLastAccessLogEntry would race: a concurrent insert
    // could advance "last" between the two calls, mirroring the wrong entry.
    final entry = AccessLogEntry(
        fromAtSign, DateTime.now().toUtc(), verbName, lookupKey);
    await _primary.replay(entry);
    await _secondary.replay(entry);
    return null;
  }

  @override
  Future<void> replay(AccessLogEntry entry) async {
    await _primary.replay(entry);
    await _secondary.replay(entry);
  }

  @override
  Future<Map<String, int>> mostVisitedAtSigns(int length) =>
      _primary.mostVisitedAtSigns(length);
  @override
  Future<Map<String, int>> mostVisitedKeys(int length) =>
      _primary.mostVisitedKeys(length);
  @override
  Future<AccessLogEntry> getLastAccessLogEntry() =>
      _primary.getLastAccessLogEntry();
  @override
  Future<AccessLogEntry?> getLastPkamAccessLogEntry() =>
      _primary.getLastPkamAccessLogEntry();
  @override
  Stream<AccessLogEntry> iterate() => _primary.iterate();
  @override
  int entriesCount() => _primary.entriesCount();
  @override
  int getSize() => _primary.getSize();
  @override
  Future<void> close() async {
    await _primary.close();
    await _secondary.close();
  }

  @override
  Stream<int> compact(bool dryRun) async* {
    // Both logs hold the same content in the same order and use the same
    // percentage, so compacting each independently drops the same entries.
    yield* _primary.compact(dryRun);
    if (!dryRun) {
      await _secondary.compact(false).drain<void>();
    }
  }
}
