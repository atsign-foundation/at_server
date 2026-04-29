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
abstract class AtPersistenceBundle {
  /// The atSign this bundle owns.
  String get atSign;

  /// Identifies which backend produced this bundle. Phase 3
  /// migration tooling reads this to detect a config change
  /// between restarts.
  AtPersistenceBackendId get backendId;

  /// The keystore for client data (target of `update` / `lookup`).
  SecondaryKeyStore<String, AtData?, AtMetaData?> get keyStore;

  /// The commit log used by sync.
  HiveAtCommitLog get commitLog;

  /// The access log used for stats and security audit.
  HiveAtAccessLog get accessLog;

  /// The notification keystore.
  HiveAtNotificationKeystore get notificationKeystore;

  /// Schedule the periodic expired-keys removal task. Generic
  /// across backends — the bundle internally drives whatever the
  /// backend needs (cron + delete sweep on Hive).
  void scheduleKeyExpireTask(int? runFrequencyMins,
      {Duration? runTimeInterval, bool skipCommits = false});

  /// Close all underlying resources. Idempotent.
  Future<void> close();
}
