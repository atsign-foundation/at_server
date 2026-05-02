import 'package:at_persistence_spec/at_persistence_spec.dart';

abstract interface class SecondaryKeyStore<K, V, T>
    implements WritableKeystore<K, V>, SynchronizableKeyStore<K, V, T> {
  /// Retrieves all keys have that expired.
  /// @return - List of keys that have expired
  Future<List<K>> getExpiredKeys();

  /// Removes all expired keys from keystore
  Future<bool> deleteExpiredKeys();

  ///Returns the list of keys, optionally keys can be searched on regular expression
  ///@param - String : This is an optional parameter that accepts the regular expression
  /// and returns keys that finds the match
  /// @return - `List<K>` : Returns list of keys
  List<K> getKeys({String? regex});

  /// Checks whether the keystore contains the key. Returns a true if key is present, else false.
  ///
  /// Synchronous flavour intended for in-process Hive-backed consumers
  /// where blocking on I/O is fine. Async-only backends (e.g. SQLite,
  /// Postgres) should use [exists] instead — the async signature is
  /// the canonical forward-compat shape.
  bool isKeyExists(String key);

  /// Returns `true` if the keystore currently contains [key], else
  /// `false`. The async flavour of [isKeyExists] — backend-agnostic
  /// consumers (e.g. at_client) should prefer this so the same call
  /// site works against Hive, SQLite, and any future backend.
  ///
  /// Should be O(1) on every backend that ships with this package
  /// (Hive uses `Box.containsKey`; SQL backends use an indexed
  /// `SELECT 1 ... LIMIT 1`). Consumers may rely on it being
  /// significantly cheaper than `getKeys(regex: '^exact$')` or
  /// `get(key) != null`.
  Future<bool> exists(String key);

  /// Stream the keystore keys that match [pattern]. Backend-portable
  /// successor to [getKeys] — callers that want structured filtering
  /// (by sharedBy / sharedWith / namespace / idPrefix) should use
  /// this instead of building regular expressions.
  ///
  /// By default, expired or not-yet-born keys are excluded; pass
  /// `includeExpired: true` to surface them.
  ///
  /// [orderBy] controls the result order. `null` (default) means
  /// "the backend's natural order" — Hive insertion order, SQL
  /// primary-key order. Pick a member of [OrderByKey] for a
  /// specific ordering; on backends without an index for that
  /// ordering, the impl materialises and sorts in memory
  /// (O(N log N)).
  ///
  /// [limit] caps the number of keys yielded; [skip] discards the
  /// first N. Both default to "no limit" / "no skip".
  Stream<String> scanKeys(
    KeyPattern pattern, {
    bool includeExpired = false,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  });

  /// Bulk fetch — returns the values for every key in [keys] that is
  /// currently present in the keystore. Keys that are absent are
  /// **not** included in the returned map; callers that need to know
  /// which inputs missed should compare `result.keys` against
  /// `keys.toSet()`.
  ///
  /// Cheaper than N individual [get] calls when [keys] is large
  /// because the implementation amortises whatever per-call overhead
  /// the underlying backend has (Hive: box-open cost; SQL backends:
  /// network round-trip + statement preparation).
  ///
  /// Hive impl: O(box-size) — iterates the box once, picks out the
  /// requested keys.
  /// SQL impl (Phase 4): `SELECT … WHERE key IN (?, ?, …)`, chunked
  /// at the parameter limit (~999 on SQLite).
  ///
  /// Duplicates in [keys] are de-duplicated; passing the same key
  /// twice produces at most one map entry.
  Future<Map<K, V>> getMany(List<K> keys);

  /// Bulk delete — removes every key in [keys] from the keystore.
  /// Returns the number of keys actually removed. Some keys may
  /// already be gone (race-tolerant): the returned count reflects
  /// the keys that existed at deletion time, not the input length.
  ///
  /// On the secondary keystore, each removal still emits its own
  /// commit-log entry unless [skipCommit] is `true` — so sync
  /// continues to work as expected. Pass `skipCommit: true` for
  /// server-local sweeps (e.g. expired-key cleanup) where you
  /// don't want each delete bumping the local `commitId`.
  ///
  /// Hive impl: batched `Box.deleteAll`.
  /// SQL impl (Phase 4): `DELETE FROM keystore WHERE key IN (?, ?,
  /// …)` inside a single transaction.
  ///
  /// Empty [keys] is a no-op that returns 0.
  Future<int> removeMany(List<K> keys, {bool skipCommit = false});

  /// Broadcast stream of [KeyStoreChange] events — one per
  /// successful mutation that affects the key set or stored value:
  /// `create()` emits [KeyAdded]; the update path of `put()` (and
  /// `putMeta` / `putAll` when they write) emits [KeyUpdated];
  /// `remove()` and `removeMany()` emit [KeyRemoved] per
  /// actually-removed key. Failed writes do not emit.
  ///
  /// `clear()`-style bulk wipes do NOT emit per-key events
  /// (avoiding flooding); listeners that need to handle those
  /// should respond to higher-level lifecycle signals instead.
  ///
  /// Broadcast semantics: late subscribers do NOT receive events
  /// emitted before they subscribed. Each subscriber gets every
  /// event from subscription onward; multiple subscribers all see
  /// every event independently.
  ///
  /// Hive impl: `StreamController.broadcast()` fired synchronously
  /// from each mutator. SQL impls (Phase 4): change-log table +
  /// trigger, polled or pushed depending on backend.
  Stream<KeyStoreChange> get changes;

  /// Run [body] as a transaction. Mutations performed via the
  /// supplied [KeyStoreTxn] handle are buffered in memory; reads
  /// via the handle see the buffered state on top of the
  /// underlying keystore. At successful body completion the
  /// buffered mutations are applied to the keystore in body
  /// order (and `changes` events fire as each is applied). If the
  /// body throws, the buffered mutations are dropped, no `changes`
  /// events fire, and the exception propagates to the caller.
  ///
  /// Hive impls provide best-effort atomicity: writes are
  /// per-flush durable, but a process crash mid-commit can leave
  /// the keystore with a subset of the buffered ops applied. SQL
  /// impls (Phase 4) provide true atomicity via
  /// `BEGIN IMMEDIATE` / `COMMIT`.
  ///
  /// The [KeyStoreTxn] handle is valid only for the duration of
  /// [body]; after `transaction` returns, calls on the handle are
  /// undefined.
  Future<R> transaction<R>(Future<R> Function(KeyStoreTxn<K, V, T> txn) body);

  /// `true` when this keystore can push value-field predicates
  /// down to its native query plan ([queryByPath] is then a real
  /// indexed query). `false` when [queryByPath] is unsupported
  /// and consumers must fall back to a `scanKeys` + in-memory
  /// filter.
  ///
  /// Hive backends return `false`. SQL backends (Phase 4) flip
  /// this to `true` once they've defined the indexed-query
  /// schema.
  bool get supportsPathQueries;

  /// Stream every (key, value, metadata) entry matching [keyPattern]
  /// AND [predicate]. The predicate is evaluated against the value's
  /// JSON-shaped fields (e.g. `PathEquals(['obj', 'amount'], 100)`).
  ///
  /// Backends MUST throw [UnsupportedError] when called and
  /// [supportsPathQueries] is `false`. Consumers should gate on
  /// the flag:
  ///
  /// ```dart
  /// if (keyStore.supportsPathQueries) {
  ///   await for (final e in keyStore.queryByPath(
  ///     keyPattern: KeyPattern(namespace: 'invoices'),
  ///     predicate: PathEquals(['obj', 'status'], 'unpaid'),
  ///   )) { /* ... */ }
  /// } else {
  ///   // Fall back: scanKeys + getMany + in-memory filter.
  /// }
  /// ```
  ///
  /// [orderBy], [limit], [skip] mirror [scanKeys].
  Stream<KeyEntry<K, V, T>> queryByPath({
    required KeyPattern keyPattern,
    required Predicate predicate,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  });

  /// `true` when this keystore can produce real isolated
  /// snapshots ([snapshot] returns a handle whose reads observe
  /// the keystore's state at snapshot-creation time, ignoring
  /// concurrent writes). `false` when the snapshot handle
  /// delegates to live state — Hive backends.
  bool get supportsSnapshots;

  /// Take a snapshot of the keystore's current state. On SQL
  /// backends this is real MVCC (BEGIN/COMMIT); on Hive it's a
  /// best-effort pass-through to live state. Always [release]
  /// the handle when done.
  ///
  /// Consumers that require real isolation should gate on
  /// [supportsSnapshots] before using the handle's reads as a
  /// consistency boundary.
  Future<KeyStoreSnapshot<K, V, T>> snapshot();

  /// Diagnostic snapshot of the keystore's state — total counts,
  /// TTL/TTB key counts, approximate size, and the
  /// oldest/newest createdAt timestamps. Not load-bearing —
  /// intended for operator dashboards (e.g. an
  /// `AtClient.diagnostics()` surface), not for runtime decisions
  /// on a hot path.
  ///
  /// Hive impls iterate the box once to compute the result
  /// (O(N)); SQL impls use indexed aggregates (O(log N) or O(1)
  /// for cached counts).
  Future<KeyStoreStats> stats();

  /// A SecondaryKeyStore has an associated commit log
  AtLogType? get commitLog => null;

  /// A SecondaryKeyStore has an associated commit log
  set commitLog(AtLogType? log) {}
}
