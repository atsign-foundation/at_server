import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Builds and owns the lifecycle of all per-atSign persistence
/// resources for an at_server.
///
/// The Phase 1 design intentionally hides the choice of backend
/// (Hive today, RDBMS tomorrow) behind a single abstraction so
/// `AtSecondaryServerImpl` can be wired up without reaching for
/// a `getInstance()` of any particular implementation.
abstract class AtPersistenceFactory {
  /// Identifies which backend this factory produces.
  AtPersistenceBackendId get backendId;

  /// Build a fully-initialised [AtPersistenceBundle] for [atSign].
  ///
  /// Calling this twice for the same atSign returns the **same**
  /// bundle — the factory owns the per-atSign lifecycle. Callers
  /// should not try to manage it themselves.
  ///
  /// Throws [ArgumentError] if [config] does not match
  /// [backendId].
  Future<AtPersistenceBundle> initialize(
      String atSign, AtPersistenceConfig config);

  /// Returns the bundle if [initialize] has been called for [atSign],
  /// otherwise null. Useful for code paths that should be no-ops
  /// when persistence is not yet wired (e.g. metrics on a
  /// not-yet-started secondary).
  AtPersistenceBundle? bundleFor(String atSign);

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
  AtKeyValueStore<String, AtData?, AtMetaData?> get keyValueStore;

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
}
