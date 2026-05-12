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
/// Re-parented to [KeyValueStore] (rather than [AtKeyValueStore])
/// because the notification queue has no commit log — sync is the
/// wrong abstraction for it. The metadata-triplet
/// ([AtKeyValueStore.putMeta] / [AtKeyValueStore.putAll] /
/// [AtKeyValueStore.getMeta]) and predicate-query surface are not
/// part of the notification contract.
abstract class AtNotificationKeystore
    implements KeyValueStore<dynamic, dynamic>, Compactable {
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

  /// Total entry count. Used by operators / metrics.
  int entriesCount();

  /// Approximate on-disk size in bytes.
  int getSize();

  /// Compact the notification queue. If [dryRun] is `true`, yields
  /// each notification key that WOULD be removed without performing
  /// the deletion. If `false`, performs the compaction and yields
  /// each key as it is removed.
  @override
  Stream<String> compact(bool dryRun);
}
