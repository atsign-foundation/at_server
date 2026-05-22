import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_commit_log_keystore.dart';
import 'package:at_utils/at_logger.dart';

import 'hive_access_log_keystore.dart';

/// Hive-backed [AtPersistenceFactory]. Produces
/// [HiveAtPersistenceBundle] instances and owns their lifecycle.
class HiveAtPersistenceFactory implements AtPersistenceFactory {
  final _logger = AtSignLogger('HiveAtPersistenceFactory');

  final Map<String, HiveAtPersistenceBundle> _bundles = {};

  @override
  AtPersistenceBackendId get backendId => AtPersistenceBackendId.hive;

  @override
  Future<AtPersistenceBundle> initialize(
      String atSign, AtPersistenceConfig config) async {
    if (config is! HivePersistenceConfig) {
      throw ArgumentError(
          'HiveAtPersistenceFactory expects HivePersistenceConfig, '
          'got ${config.runtimeType}');
    }

    final existing = _bundles[atSign];
    if (existing != null) return existing;

    _logger.info('Initialising Hive persistence for $atSign');

    // 1. Commit log (optional capability). Server bundles append
    //    every write to it for sync; commit-log-free client bundles
    //    skip it entirely and never open `config.commitLogPath`.
    HiveAtCommitLog? commitLog;
    if (config.enableCommitLog) {
      final commitLogKeyStore = HiveCommitLogKeyStore(atSign);
      await commitLogKeyStore.init(config.commitLogPath, isLazy: false);
      commitLog = HiveAtCommitLog(commitLogKeyStore);
    }

    // 2. Access log (optional capability).
    HiveAtAccessLog? accessLog;
    if (config.enableAccessLog) {
      final accessLogKeyStore = HiveAccessLogKeyStore(atSign);
      await accessLogKeyStore.init(config.accessLogPath);
      accessLog = HiveAtAccessLog(accessLogKeyStore);
    }

    // 3. Notification keystore (optional capability).
    HiveAtNotificationKeystore? notificationKeystore;
    if (config.enableNotificationKeystore) {
      notificationKeystore = HiveAtNotificationKeystore(atSign);
      await notificationKeystore.init(config.notificationStoragePath);
    }

    // 4. Secondary keystore. Owns its own Hive box, encryption
    //    secret, and cron-driven key-expiry sweep (former roles
    //    of the now-retired HivePersistenceManager). The commit
    //    log lives inside the keystore: when present, every write
    //    appends to it for sync. Server bundles always have one;
    //    commit-log-free client bundles leave `commitLog` null.
    final keyValueStore = HiveAtKeyValueStore(atSign);
    keyValueStore.commitLog = commitLog;
    await keyValueStore.init(config.storagePath);

    final bundle = HiveAtPersistenceBundle._(
      atSign: atSign,
      keyValueStore: keyValueStore,
      accessLog: accessLog,
      notificationKeystore: notificationKeystore,
    );
    _bundles[atSign] = bundle;
    return bundle;
  }

  @override
  AtPersistenceBundle? bundleFor(String atSign) => _bundles[atSign];

  @override
  Future<void> close() async {
    final bundles = _bundles.values.toList();
    _bundles.clear();
    for (final b in bundles) {
      try {
        await b.close();
      } catch (e, st) {
        _logger.warning('Error closing bundle for ${b.atSign}: $e\n$st');
      }
    }
  }
}

/// Hive-backed [AtPersistenceBundle].
class HiveAtPersistenceBundle implements AtPersistenceBundle {
  @override
  final String atSign;

  // Typed at the concrete on HiveAtPersistenceBundle so [clear]
  // can reach the Hive-specific in-memory caches. The abstract
  // [AtPersistenceBundle.keyValueStore] still surfaces it as
  // AtKeyValueStore<...>.
  @override
  final HiveAtKeyValueStore keyValueStore;

  /// Nullable per the slim-bundle design: only populated when the
  /// config opts in via [HivePersistenceConfig.enableAccessLog].
  @override
  final HiveAtAccessLog? accessLog;

  /// Nullable per the slim-bundle design: only populated when the
  /// config opts in via [HivePersistenceConfig.enableNotificationKeystore].
  @override
  final HiveAtNotificationKeystore? notificationKeystore;

  bool _closed = false;

  HiveAtPersistenceBundle._({
    required this.atSign,
    required this.keyValueStore,
    required this.accessLog,
    required this.notificationKeystore,
  });

  @override
  AtPersistenceBackendId get backendId => AtPersistenceBackendId.hive;

  @override
  Future<void> clear() async {
    if (_closed) {
      throw StateError(
          'Cannot clear a closed HiveAtPersistenceBundle for $atSign');
    }
    // Order: keystore, commit log (via keystore), access log,
    // notification keystore. Caller-visible state and in-memory
    // caches are reset; underlying Hive boxes stay open for fast
    // reuse in subsequent tests.
    await keyValueStore.clear();
    final commitLog = keyValueStore.commitLog;
    if (commitLog is HiveAtCommitLog) {
      await commitLog.commitLogKeyStore.getBox().clear();
    }
    await accessLog?.clear();
    await notificationKeystore?.clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Order is the inverse of [HiveAtPersistenceFactory.initialize]:
    // close the keystore first (so any in-flight expiry task
    // observes a closed box), then logs and notifications.
    await keyValueStore.close();
    final commitLog = keyValueStore.commitLog;
    if (commitLog is HiveAtCommitLog) {
      await commitLog.close();
    }
    await accessLog?.close();
    await notificationKeystore?.close();
  }
}
