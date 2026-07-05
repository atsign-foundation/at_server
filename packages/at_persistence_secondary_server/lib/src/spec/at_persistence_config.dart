/// Identifies which persistence backend an [AtPersistenceFactory]
/// produces. Only [hive] ships today; future backends (e.g. SQLite,
/// Postgres) will add others without changing the enum's existing
/// values.
enum AtPersistenceBackendId { hive }

/// Open base class for backend-specific configuration. Future
/// backends subclass to add backend-specific fields without breaking
/// the [AtPersistenceFactory.initialize] signature.
///
/// The bundle has a *core* (always present: the keystore) plus
/// *optional capabilities* (the keystore's commit log, the access
/// log, the notification keystore). The `enable*` flags select which
/// optional capabilities the factory should bring up. Server configs
/// typically opt into all; client configs typically opt into the
/// keystore only.
///
/// Compactor scheduling is no longer the persistence layer's
/// concern — `at_secondary_server` owns the Timer-driven schedule
/// and the enable flags for it.
abstract class AtPersistenceConfig {
  /// The backend this config is for. Must match the
  /// [AtPersistenceFactory.backendId] you pass it to.
  AtPersistenceBackendId get backend;

  /// Where the keystore data lives.
  String get storagePath;

  /// Where the commit log lives.
  String get commitLogPath;

  /// Where the access log lives. Only consulted when
  /// [enableAccessLog] is `true`.
  String get accessLogPath;

  /// Where the notification keystore lives. Only consulted when
  /// [enableNotificationKeystore] is `true`.
  String get notificationStoragePath;

  /// Where the marker file lives. A future backend-aware factory
  /// will use this to detect backend changes between restarts; the
  /// current implementation doesn't read it, it's declared here so
  /// the field is part of the contract from day one.
  String get backendMarkerPath;

  /// Whether the access log should be initialised. Server-only —
  /// clients leave this `false` and never read the access log.
  bool get enableAccessLog;

  /// Whether the notification keystore should be initialised as
  /// persistence. Server-only — clients leave this `false` and
  /// handle notifications via the at_lookup connection instead.
  bool get enableNotificationKeystore;

  /// Whether the keystore should be initialised with a commit log.
  /// Server bundles set this `true` (every write appends to the
  /// commit log for sync). Clients that no longer rely on a commit
  /// log leave it `false`, in which case the keystore is created
  /// commit-log-free and [commitLogPath] is never consulted.
  bool get enableCommitLog;
}
