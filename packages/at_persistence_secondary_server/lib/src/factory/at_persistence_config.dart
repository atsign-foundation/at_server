/// Identifies which persistence backend an [AtPersistenceFactory]
/// produces. Phase 1 only ships [hive]; Phase 3 will add others
/// (e.g. SQLite, Postgres) without changing the enum's existing
/// values.
enum AtPersistenceBackendId { hive }

/// Open base class for backend-specific configuration. Phase 2/3
/// backends subclass to add backend-specific fields without breaking
/// the [AtPersistenceFactory.initialize] signature.
abstract class AtPersistenceConfig {
  /// The backend this config is for. Must match the
  /// [AtPersistenceFactory.backendId] you pass it to.
  AtPersistenceBackendId get backend;

  /// Where the keystore data lives.
  String get storagePath;

  /// Where the commit log lives.
  String get commitLogPath;

  /// Where the access log lives.
  String get accessLogPath;

  /// Where the notification keystore lives.
  String get notificationStoragePath;

  /// Where the marker file lives. Phase 3 will use this to detect
  /// backend changes between restarts. Phase 1 doesn't read it; it's
  /// declared here so the field is part of the contract from day one.
  String get backendMarkerPath;
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
  }) : backendMarkerPath =
            backendMarkerPath ?? '$storagePath/.persistence_backend';
}
