import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Builds and owns the lifecycle of all per-atSign persistence
/// resources for an at_server.
///
/// The design intentionally hides the choice of backend (Hive
/// today, RDBMS tomorrow) behind a single abstraction so
/// `AtSecondaryServerImpl` can be wired up without reaching for
/// a `getInstance()` of any particular implementation.
abstract class AtPersistenceFactory {
  /// Identifies which backend this factory produces.
  AtPersistenceBackendId get backendId;

  /// Build a fully-initialised [AtPersistenceBundle] for [atSign].
  ///
  /// Calling this twice for the same atSign **with the same storage
  /// locations** returns the same bundle — the factory owns the
  /// per-atSign lifecycle. Callers should not try to manage it
  /// themselves.
  ///
  /// Calling it for an atSign that already has an open bundle rooted
  /// somewhere else throws a [StateError]. One bundle per atSign is
  /// this interface's contract and [bundleFor] and [closeFor] both key
  /// on the atSign alone, so there is nowhere for a second bundle to
  /// live; returning the one it holds would answer a caller with
  /// another store's records, and the caller has no way to notice.
  /// Close the first bundle, or use a separate factory instance.
  ///
  /// Two spellings of one location are one location: the comparison is
  /// lexical first and resolves symlinks on disagreement, so `foo/bar`
  /// and `foo/./bar`, and a link and its target, are not a conflict.
  ///
  /// If a previous bundle for [atSign] has been closed (whether
  /// directly via [AtPersistenceBundle.close] or via [closeFor]),
  /// the stale entry is dropped and a fresh bundle is built — at
  /// whatever locations the new [config] names.
  ///
  /// Throws [ArgumentError] if [config] does not match
  /// [backendId].
  Future<AtPersistenceBundle> initialize(
      String atSign, AtPersistenceConfig config);

  /// Returns the open bundle if [initialize] has been called for
  /// [atSign] and the bundle is not closed; otherwise `null`.
  /// Useful for code paths that should be no-ops when persistence
  /// is not yet wired (e.g. metrics on a not-yet-started secondary).
  AtPersistenceBundle? bundleFor(String atSign);

  /// Close the bundle for [atSign] and drop the factory's reference
  /// to it. Safe to call when no bundle exists for [atSign] — the
  /// call is a no-op. After [closeFor], [bundleFor] returns `null`
  /// and [initialize] builds a fresh bundle on next call.
  Future<void> closeFor(String atSign);

  /// Close every bundle this factory has produced. Idempotent —
  /// calling twice does not throw, and calling [initialize] after
  /// [close] is allowed and starts a fresh lifecycle.
  Future<void> close();
}

/// All the per-atSign persistence resources an at_server needs,
/// produced by an [AtPersistenceFactory].
///
/// The bundle exposes three top-level resources, each of which
/// implements [Compactable]:
///   * [keyValueStore] — the main key-value store. Its internal
///     commit log (server-side; null on client-side) is reachable
///     via [AtKeyValueStore.commitLog].
///   * [accessLog] — optional audit trail (server-side only).
///   * [notificationKeystore] — optional notification queue
///     (server-side only).
///
/// Server-shaped consumers (full atSecondary) opt into all
/// capabilities; client-shaped consumers (e.g. at_client_sdk's
/// local cache) opt into the keystore only.
abstract class AtPersistenceBundle {
  /// The atSign this bundle owns.
  String get atSign;

  /// Identifies which backend produced this bundle.
  AtPersistenceBackendId get backendId;

  /// The keystore for client data (target of `update` / `lookup`).
  /// Its commit log is accessible as `keyValueStore.commitLog` —
  /// non-null on server bundles, null on client bundles.
  AtKeyValueStore<String, AtData, AtMetaData?> get keyValueStore;

  /// The access log used for stats and security audit. `null` when
  /// [AtPersistenceConfig.enableAccessLog] is `false` (typical for
  /// client-only consumers).
  AtAccessLog? get accessLog;

  /// The notification keystore. `null` when
  /// [AtPersistenceConfig.enableNotificationKeystore] is `false`.
  AtNotificationKeystore? get notificationKeystore;

  /// Drop all data from this bundle's stores while keeping the
  /// underlying connections (Hive boxes etc.) open. Idempotent.
  /// Intended for cheap per-test isolation.
  Future<void> clear();

  /// Close all underlying resources. Idempotent.
  Future<void> close();

  /// `true` after [close] has been called (whether directly on the
  /// bundle or via the owning factory). Once closed, methods on the
  /// bundle are undefined; the producing factory's [bundleFor]
  /// returns `null` and [AtPersistenceFactory.initialize] rebuilds.
  bool get isClosed;
}
