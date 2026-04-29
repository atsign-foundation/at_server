/// Identifies which persistence backend an [AtPersistenceFactory]
/// produces. Phase 1 only ships [hive]; Phase 3 will add others
/// (e.g. SQLite, Postgres) without changing the enum's existing
/// values.
enum AtPersistenceBackendId { hive }

/// Open base class for backend-specific configuration. Phase 2/3
/// backends subclass to add backend-specific fields without breaking
/// the [AtPersistenceFactory.initialize] signature.
///
/// The bundle has a *core* (always present: keystore, commit log,
/// key-expire scheduler, lifecycle) plus *optional capabilities*
/// (access log, notification keystore). The `enable*` flags select
/// which optional capabilities the factory should bring up. Server
/// configs typically opt into all; client configs typically opt
/// into core only.
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

  /// Where the marker file lives. Phase 3 will use this to detect
  /// backend changes between restarts. Phase 1 doesn't read it; it's
  /// declared here so the field is part of the contract from day one.
  String get backendMarkerPath;

  /// Whether the access log should be initialised. Server-only —
  /// clients leave this `false` and never read the access log.
  bool get enableAccessLog;

  /// Whether the notification keystore should be initialised as
  /// persistence. Server-only — clients leave this `false` and
  /// handle notifications via the at_lookup connection instead.
  bool get enableNotificationKeystore;
}

/// Hive-specific persistence configuration.
class HivePersistenceConfig implements AtPersistenceConfig {
  @override
  AtPersistenceBackendId get backend => AtPersistenceBackendId.hive;

  @override
  final String storagePath;

  @override
  final String commitLogPath;

  @override
  final String accessLogPath;

  @override
  final String notificationStoragePath;

  @override
  final String backendMarkerPath;

  @override
  final bool enableAccessLog;

  @override
  final bool enableNotificationKeystore;

  /// Whether commit IDs should be assigned by the commit log. Defaults
  /// to `true` (server side). Set `false` for client-side commit logs.
  final bool enableCommitId;

  HivePersistenceConfig({
    required this.storagePath,
    required this.commitLogPath,
    required this.accessLogPath,
    required this.notificationStoragePath,
    String? backendMarkerPath,
    this.enableCommitId = true,
    this.enableAccessLog = true,
    this.enableNotificationKeystore = true,
  }) : backendMarkerPath =
            backendMarkerPath ?? '$storagePath/.persistence_backend';

  /// Convenience constructor for atSecondary servers: opts into all
  /// optional capabilities (access log, notification keystore).
  factory HivePersistenceConfig.serverDefaults({
    required String storagePath,
    required String commitLogPath,
    required String accessLogPath,
    required String notificationStoragePath,
    String? backendMarkerPath,
  }) =>
      HivePersistenceConfig(
        storagePath: storagePath,
        commitLogPath: commitLogPath,
        accessLogPath: accessLogPath,
        notificationStoragePath: notificationStoragePath,
        backendMarkerPath: backendMarkerPath,
        enableCommitId: true,
        enableAccessLog: true,
        enableNotificationKeystore: true,
      );

  /// Convenience constructor for at_client_sdk-shaped consumers:
  /// opts in to keystore + commit log only (with `enableCommitId`
  /// off — the client doesn't auto-assign commitIds, the server
  /// does). Access log and notification keystore stay disabled;
  /// their paths are still required on the abstract config but
  /// the factory will never open boxes at them.
  factory HivePersistenceConfig.clientDefaults({
    required String storagePath,
    required String commitLogPath,
    String? backendMarkerPath,
  }) =>
      HivePersistenceConfig(
        storagePath: storagePath,
        commitLogPath: commitLogPath,
        accessLogPath: '$storagePath/.unused_access_log',
        notificationStoragePath: '$storagePath/.unused_notifications',
        backendMarkerPath: backendMarkerPath,
        enableCommitId: false,
        enableAccessLog: false,
        enableNotificationKeystore: false,
      );
}
