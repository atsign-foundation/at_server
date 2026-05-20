import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// The unified backend-agnostic key-value store contract. Implemented
/// by every keystore in this package — at_server's main store
/// ([AtKeyValueStore]), the notification queue
/// ([AtNotificationKeystore]), and any future backends (SQLite,
/// Postgres). Holds the full CRUD + rich-surface contract; the
/// sync-coupled extras (commit log, metadata, predicate queries)
/// live in [AtKeyValueStore].
abstract interface class KeyValueStore<K, V> {
  /// Subclasses should put any necessary post-construction async
  /// initialization in this method.
  Future<void> initialize() async {}

  // ---------------------------------------------------------------
  // Single-key reads / writes
  // ---------------------------------------------------------------

  /// Retrieves the value mapped to [key], or `null` if no mapping
  /// exists. Implementations may also throw a backend-specific
  /// not-found exception (e.g. `KeyNotFoundException`) instead of
  /// returning `null` — consult the concrete impl.
  Future<V?> get(K key);

  /// Associates [value] with [key]. If a mapping already exists,
  /// the old value is replaced.
  ///
  /// Returns the commit-log sequence number assigned to this write,
  /// or `null` if no sequence number was produced (when [skipCommit]
  /// is `true`, or when this backend does not maintain a commit
  /// log).
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<int?> put(K key, V value, {bool skipCommit = false});

  /// If no mapping exists for [key], associates it with [value] and
  /// returns the commit-log sequence number; otherwise behaviour is
  /// implementation-defined (typically throws).
  ///
  /// Returns the commit-log sequence number assigned to this write,
  /// or `null` if no sequence number was produced.
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<int?> create(K key, V value, {bool skipCommit = false});

  /// Removes the mapping for [key] if present.
  ///
  /// Returns the commit-log sequence number assigned to this
  /// deletion, or `null` if no sequence number was produced.
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<int?> remove(K key, {bool skipCommit = false});

  /// Hooks invoked synchronously before a single-key remove. Each
  /// hook is awaited in order; if a hook throws, the remove is
  /// aborted and the exception propagates.
  List<Future<void> Function(String key, {required bool skipCommit})>
      get preRemoveHooks;

  /// Hooks invoked synchronously after a single-key remove. Each
  /// hook is awaited in order. Hook exceptions are propagated to
  /// the caller after the remove has already happened.
  List<Future<void> Function(String key, {required bool skipCommit})>
      get postRemoveHooks;

  // ---------------------------------------------------------------
  // Expiry
  // ---------------------------------------------------------------

  /// Streams all keys that have expired. The returned `Future`
  /// completes once the backend has accepted the request (surfacing
  /// any setup failure eagerly); the `Stream` then yields the keys.
  Future<Stream<K>> getExpiredKeys();

  /// Removes all expired keys. Deletes are local-only — they are
  /// NOT appended to the commit log, so an expiry sweep never
  /// advances the local `commitId` and never propagates to other
  /// secondaries via sync. Expiry is treated as backend
  /// maintenance, not a sync-worthy mutation; clients drop expired
  /// keys independently using their own TTL bookkeeping.
  Future<bool> deleteExpiredKeys();

  // ---------------------------------------------------------------
  // Listing / existence
  // ---------------------------------------------------------------

  /// Streams the keys, optionally filtered by [regex]. The returned
  /// `Future` completes once the backend has accepted the request —
  /// setup failures (store not open, invalid [regex]) reject the
  /// `Future` eagerly rather than surfacing mid-stream; the `Stream`
  /// then yields the matching keys.
  Future<Stream<K>> getKeys({String? regex});

  /// Returns `true` if the keystore currently contains [key],
  /// else `false`. The backend-agnostic existence check — the same
  /// call site works against every backend.
  ///
  /// Should be O(1) on every backend that ships with this
  /// package (Hive uses `Box.containsKey`; SQL backends use an
  /// indexed `SELECT 1 ... LIMIT 1`).
  Future<bool> exists(String key);

  /// Stream the keystore keys that match [pattern]. Backend-
  /// portable successor to [getKeys] — callers that want
  /// structured filtering (by sharedBy / sharedWith / namespace /
  /// idPrefix) should use this instead of building regular
  /// expressions.
  ///
  /// By default, expired or not-yet-born keys are excluded; pass
  /// `includeExpired: true` to surface them.
  ///
  /// [orderBy] controls the result order. `null` (default) means
  /// "the backend's natural order". [limit] caps the number of
  /// keys yielded; [skip] discards the first N.
  ///
  /// The returned `Future` completes once the backend has accepted
  /// the request; the `Stream` then yields the matching keys.
  Future<Stream<String>> scanKeys(
    KeyPattern pattern, {
    bool includeExpired = false,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  });

  // ---------------------------------------------------------------
  // Bulk
  // ---------------------------------------------------------------

  /// Bulk fetch — returns the values for every key in [keys] that
  /// is currently present. Keys that are absent are NOT included
  /// in the returned map.
  Future<Map<K, V>> getMany(List<K> keys);

  /// Bulk delete — removes every key in [keys]. Returns the count
  /// of keys actually removed (race-tolerant: input keys may
  /// already have been deleted).
  Future<int> removeMany(List<K> keys, {bool skipCommit = false});

  // ---------------------------------------------------------------
  // Reactive / transactional / diagnostic
  // ---------------------------------------------------------------

  /// Broadcast stream of [KeyStoreChange] events — one per
  /// successful mutation that affects the key set or stored
  /// value. Late subscribers do not receive earlier events.
  Stream<KeyStoreChange> get changes;

  /// Run [body] as a transaction. Mutations performed via the
  /// supplied handle are buffered in memory and applied in body
  /// order on successful completion; if the body throws, the
  /// buffer is dropped and the exception propagates.
  ///
  /// Hive impls provide best-effort atomicity; SQL impls (Phase 4)
  /// provide true atomicity.
  Future<R> transaction<R>(
      Future<R> Function(KeyStoreTxn<K, V, dynamic> txn) body);

  /// `true` when this keystore can produce real isolated
  /// snapshots ([snapshot] returns a handle whose reads observe
  /// the keystore's state at snapshot-creation time, ignoring
  /// concurrent writes). `false` when the handle delegates to
  /// live state (Hive backends).
  bool get supportsSnapshots;

  /// Take a snapshot of the keystore's current state. Always
  /// [release] the handle when done.
  Future<KeyStoreSnapshot<K, V, dynamic>> snapshot();

  /// Diagnostic snapshot of the keystore's state — total counts,
  /// TTL/TTB key counts, approximate size, oldest/newest
  /// timestamps. Intended for operator dashboards, not for
  /// runtime decisions on a hot path.
  Future<KeyStoreStats> stats();
}

/// Enumeration indicating the store type.
// ignore: constant_identifier_names
enum StoreType { ROOT, SECONDARY }
