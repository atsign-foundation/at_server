import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:path/path.dart' as p;

/// SQLite-specific persistence configuration.
///
/// Unlike Hive (which spreads the keystore / commit log / access log /
/// notifications across four storage directories), the SQLite backend
/// keeps all of an atSign's data in a single `atsign.db` file under a
/// per-atSign directory: `<storagePath>/<atSign>/atsign.db`. The four
/// path getters the [AtPersistenceConfig] contract requires therefore all
/// resolve to the one storage root — they are vestigial for a single-file
/// backend but kept for interface conformance.
class SqlitePersistenceConfig implements AtPersistenceConfig {
  @override
  AtPersistenceBackendId get backend => AtPersistenceBackendId.sqlite;

  /// The SQLite storage root. Per-atSign databases live at
  /// `<storagePath>/<atSign>/atsign.db`, so this is typically a
  /// `.../sqlite` directory sibling to the Hive tree.
  @override
  final String storagePath;

  // Single-file backend: these all resolve to the storage root.
  @override
  String get commitLogPath => storagePath;
  @override
  String get accessLogPath => storagePath;
  @override
  String get notificationStoragePath => storagePath;

  @override
  final String backendMarkerPath;

  @override
  final bool enableAccessLog;

  @override
  final bool enableNotificationKeystore;

  @override
  final bool enableCommitLog;

  SqlitePersistenceConfig({
    required this.storagePath,
    String? backendMarkerPath,
    this.enableAccessLog = true,
    this.enableNotificationKeystore = true,
    this.enableCommitLog = true,
  }) : backendMarkerPath =
            backendMarkerPath ?? p.join(storagePath, '.persistence_backend');

  /// The `.db` file path for [atSign]: `<storagePath>/<atSign>/atsign.db`.
  String dbPathFor(String atSign) => p.join(storagePath, atSign, 'atsign.db');

  /// atSecondary server config: all optional capabilities on.
  factory SqlitePersistenceConfig.serverDefaults({
    required String storagePath,
    String? backendMarkerPath,
  }) =>
      SqlitePersistenceConfig(
        storagePath: storagePath,
        backendMarkerPath: backendMarkerPath,
        enableAccessLog: true,
        enableNotificationKeystore: true,
        enableCommitLog: true,
      );

  /// at_client-shaped config: keystore only, commit-log-free.
  factory SqlitePersistenceConfig.clientDefaults({
    required String storagePath,
    String? backendMarkerPath,
  }) =>
      SqlitePersistenceConfig(
        storagePath: storagePath,
        backendMarkerPath: backendMarkerPath,
        enableAccessLog: false,
        enableNotificationKeystore: false,
        enableCommitLog: false,
      );
}
