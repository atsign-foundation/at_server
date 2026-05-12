import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// Abstract contract for a queue of pending atSign-to-atSign
/// notifications, persisted server-side. The Hive-backed
/// implementation is [HiveAtNotificationKeystore]; future backends
/// (e.g. SQLite, Postgres) provide their own.
///
/// Notifications-as-storage is a server-only concept — clients
/// (e.g. `at_client_sdk`) handle notifications via the at_lookup
/// connection rather than persisting them locally. Bundle consumers
/// that run a full secondary opt into this capability via
/// [AtPersistenceConfig.enableNotificationKeystore]; client-only
/// consumers leave it disabled.
///
/// This abstract mirrors the public surface of the Hive concrete:
/// it implements [AtKeyValueStore] (because notifications are
/// keyed by notification id) and [AtLogType] (because the
/// notification queue is compactable on the same access-log
/// dimensions). Type parameters intentionally default to `dynamic`
/// — the legacy keystore is loosely typed and Phase 2 keeps that
/// shape; tightening to `<String, AtNotification?, AtMetaData?>`
/// is left for a future cleanup that also rewrites the tests.
abstract class AtNotificationKeystore
    implements AtKeyValueStore, AtLogType<String, AtNotification> {
  /// Initialize the underlying storage rooted at [path]. Called once
  /// at bootstrap; implementation-defined what `path` means
  /// (directory for Hive, connection string for SQL backends, ...).
  Future<void> init(String path);

  /// Close the underlying storage handle.
  Future<void> close();

  /// Iterate every notification entry. Used by the persistence
  /// migrator to copy notification content from one backend to
  /// another.
  Stream<AtNotification> iterate();
}
