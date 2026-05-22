import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

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

  HivePersistenceConfig({
    required this.storagePath,
    required this.commitLogPath,
    required this.accessLogPath,
    required this.notificationStoragePath,
    String? backendMarkerPath,
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
        enableAccessLog: true,
        enableNotificationKeystore: true,
      );

  /// Convenience constructor for at_client_sdk-shaped consumers:
  /// opts in to keystore only.
  factory HivePersistenceConfig.clientDefaults({
    required String storagePath,
    String? backendMarkerPath,
  }) =>
      HivePersistenceConfig(
        storagePath: storagePath,
        commitLogPath: '$storagePath/.unused_commit_log',
        accessLogPath: '$storagePath/.unused_access_log',
        notificationStoragePath: '$storagePath/.unused_notifications',
        backendMarkerPath: backendMarkerPath,
        enableAccessLog: false,
        enableNotificationKeystore: false,
      );
}
