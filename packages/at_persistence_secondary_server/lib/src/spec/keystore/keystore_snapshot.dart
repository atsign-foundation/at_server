import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// A read-only view of a [AtKeyValueStore] taken at snapshot
/// creation time. Backends with real MVCC support (SQL: SQLite,
/// Postgres) materialise the snapshot via `BEGIN`/`COMMIT` so
/// concurrent writes don't bleed into reads through this handle.
/// Hive's impl is a *best-effort* shim that delegates to the live
/// keystore — there's no true MVCC, so reads through the handle
/// observe live state, not snapshot-creation state.
///
/// Always check [`AtKeyValueStore.supportsSnapshots`] before
/// relying on isolation. On `false` backends, treat the handle
/// as a convenience pass-through with the same consistency
/// guarantees as direct keystore access.
///
/// Lifetime: call [release] when done. After release, methods on
/// the handle are undefined.
abstract class KeyStoreSnapshot<K, V, T> {
  /// Returns the value of [key] as visible to this snapshot. On
  /// `supportsSnapshots == true` backends this is the value at
  /// snapshot-creation time; on `false` backends it's the live
  /// value at call time.
  Future<V?> get(K key);

  /// Streams keys matching [pattern]. Same isolation caveat as
  /// [get]: real on SQL backends, best-effort on Hive.
  Stream<K> scanKeys(KeyPattern pattern);

  /// Release the snapshot. On SQL backends this commits/rolls
  /// back the underlying transaction; on Hive it's a no-op.
  /// Calling [release] multiple times is harmless. After release,
  /// other methods on the handle are undefined.
  Future<void> release();
}
