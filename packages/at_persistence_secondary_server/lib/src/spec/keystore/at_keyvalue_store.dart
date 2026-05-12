import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart'
    show AtCommitLog;
import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// The at_server-flavour key-value store. Extends [KeyValueStore]
/// with the sync-coupled surface that only makes sense for a
/// keystore that participates in atSign-to-atSign sync:
///
///   * a (possibly-null) [commitLog] that records every mutation
///   * the [putMeta] / [putAll] / [getMeta] metadata triplet that
///     `at_secondary_server` uses on the update / lookup paths
///   * the [queryByPath] / [supportsPathQueries] predicate-query
///     pair that lights up on SQL backends in Phase 4
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
