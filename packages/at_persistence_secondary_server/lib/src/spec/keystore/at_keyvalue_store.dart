import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// The at_server-flavour key-value store. Extends [KeyValueStore]
/// with the sync-coupled surface that only makes sense for a
/// keystore that participates in atSign-to-atSign sync:
///
///   * a (possibly-null) [commitLog] that records every mutation
///   * the [putMeta] / [putAll] / [getMeta] metadata triplet that
///     `at_secondary_server` uses on the update / lookup paths
///   * the structured-key [scanKeys] surface — [KeyPattern]
///     filters by atKey shape (sharedBy / sharedWith / namespace /
///     idPrefix), so it lives on the atKey-aware tier rather than
///     the generic [KeyValueStore]
///   * the [queryByPath] / [supportsPathQueries] predicate-query
///     pair that lights up on a future SQL backend
///
/// The commit log is nullable: server-side bundles always have one
/// (writes append to it for sync); client-side bundles may not
/// (clients track sync via a different mechanism). The server's
/// bootstrap is responsible for the single non-null assertion and
/// binding the result to a non-nullable local — downstream
/// consumers don't re-check.
///
/// Compaction lives on the resources that actually get compacted
/// ([AtCommitLog], [AtAccessLog], [AtNotificationKeystore]); the
/// keystore itself is not compactable in the cron-driven sense.
abstract interface class AtKeyValueStore<K, V, T>
    implements KeyValueStore<K, V>, Compactable {
  /// The commit log for this keystore, or `null` if this is an
  /// un-synced (client-side) keystore.
  ///
  /// Server bundles MUST have a non-null commit log; the server's
  /// bootstrap asserts this once and binds to a non-nullable local
  /// for downstream consumers. Client bundles MAY return `null`
  /// here — every write returns `null` from
  /// [KeyValueStore.put] / [KeyValueStore.create] /
  /// [KeyValueStore.remove] in that case.
  AtCommitLog? get commitLog => null;

  /// Server-side bootstrap may set this once during bundle
  /// construction; client-side bundles leave it `null`.
  set commitLog(AtCommitLog? log) {}

  /// Smallest non-null `availableAt` among entries that have not
  /// yet become available (`availableAt > asOf`, [asOf] defaulting
  /// to now), or `null` if there are none. Drives a TTB-sweep
  /// wake-up timer.
  ///
  /// Note the strict-greater-than filter: keys that are already
  /// born are excluded. TTB doesn't have TTL's "becomes actionable
  /// when crossed → deleted soon after" lifecycle — a born key
  /// stays in the store, so only the not-yet-born subset is
  /// interesting for a wake-up timer.
  ///
  /// Snapshot semantics: best-effort with respect to concurrent
  /// mutations, as for [KeyValueStore.nextExpiresAt].
  ///
  /// MUST be O(1)-or-better than a full-store scan on any backend
  /// bundled with this package.
  Future<DateTime?> nextAvailableAt({DateTime? asOf});

  /// Up to [limit] keys whose `availableAt` is in `(since, asOf]` —
  /// keys that crossed the born threshold since the caller's last
  /// sweep watermark. Ascending-`availableAt` order; [asOf]
  /// defaults to now.
  ///
  /// The watermark pattern: born keys are persistent (unlike
  /// expired keys, which a sweep drains), so "all born keys" is
  /// useless as a trigger signal — every call would return the
  /// same set. Callers MUST track the largest `availableAt` they
  /// have already processed and pass it as [since] (exclusive).
  /// The first sweep may pass `DateTime(0)` or a persisted
  /// watermark. A key whose `availableAt == since` is NOT yielded;
  /// one whose `availableAt == asOf` IS.
  ///
  /// The watermark is deliberately caller-side state — see the
  /// audit's §4.3: it adds no per-entry server state and composes
  /// with multiple independent readers. If a future caller needs
  /// server-side "processed" tracking instead, revisit this
  /// contract before building around it.
  Future<Stream<K>> peekNewlyAvailable({
    required DateTime since,
    DateTime? asOf,
    int? limit,
  });

  /// Updates the metadata for [key] without touching its value.
  /// Returns the commit-log sequence number assigned to this
  /// write, or `null` if no sequence number was produced.
  Future<int?> putMeta(K key, T metadata);

  /// Writes [value] and [metadata] for [key] atomically. Returns
  /// the commit-log sequence number assigned to this write, or
  /// `null` if no sequence number was produced.
  Future<int?> putAll(K key, V value, T metadata);

  /// Returns the metadata associated with [key].
  Future<T> getMeta(K key);

  /// Stream the keystore keys that match [pattern]. Backend-
  /// portable successor to [KeyValueStore.getKeys] for callers
  /// that want structured filtering rather than building regular
  /// expressions.
  ///
  /// The return type is `Stream<String>` (rather than `Stream<K>`):
  /// [KeyPattern]'s fields — `sharedBy`, `sharedWith`, `namespace`,
  /// `idPrefix` — are atKey-shaped, so the result is inherently a
  /// stream of atKey strings.
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

  /// Take a snapshot of the keystore's current state. Overrides
  /// [KeyValueStore.snapshot] with the atKey-aware snapshot type
  /// that surfaces [AtKeyValueStoreSnapshot.scanKeys].
  @override
  Future<AtKeyValueStoreSnapshot<K, V, T>> snapshot();

  /// `true` when this keystore can push value-field predicates
  /// down to its native query plan ([queryByPath] is then a real
  /// indexed query). `false` when [queryByPath] is unsupported
  /// and consumers must fall back to a `scanKeys` + in-memory
  /// filter.
  ///
  /// Hive backends return `false`. A future SQL backend flips
  /// this to `true` once it has defined the indexed-query schema.
  bool get supportsPathQueries;

  /// Stream every (key, value, metadata) entry matching
  /// [keyPattern] AND [predicate]. The predicate is evaluated
  /// against the value's JSON-shaped fields.
  ///
  /// Backends MUST throw [UnsupportedError] when called and
  /// [supportsPathQueries] is `false`. Consumers should gate on
  /// the flag before calling.
  Stream<KeyEntry<K, V, T>> queryByPath({
    required KeyPattern keyPattern,
    required Predicate predicate,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  });

  /// Compact the keystore. The Hive impl delegates to its internal
  /// commit log's compaction; a client-side bundle (no commit log)
  /// is a no-op and yields nothing.
  ///
  /// Element type is `Object` to allow concrete impls to yield
  /// whatever the underlying compaction operates on (commit ids for
  /// server-side; nothing for client-side).
  @override
  Stream<Object> compact(bool dryRun);
}
