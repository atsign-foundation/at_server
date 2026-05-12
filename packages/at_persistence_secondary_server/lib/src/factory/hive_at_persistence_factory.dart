import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_log_keystore.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_log_keystore.dart';
import 'package:at_utils/at_logger.dart';

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

    // 1. Commit log (always present — core capability). The
    //    "client" flavour stores commitIds assigned by the server
    //    side via update(...); the "server" flavour auto-assigns
    //    on commit().
    final HiveAtCommitLog commitLog;
    final CommitLogKeyStore commitLogKeyStore;
    if (config.enableCommitId) {
      commitLogKeyStore = CommitLogKeyStore(atSign);
      await commitLogKeyStore.init(config.commitLogPath, isLazy: false);
      commitLog = HiveAtCommitLog(commitLogKeyStore);
    } else {
      commitLogKeyStore = ClientCommitLogKeyStore(atSign);
      await commitLogKeyStore.init(config.commitLogPath, isLazy: false);
      commitLog = HiveClientAtCommitLog(commitLogKeyStore);
    }

    // 2. Access log (optional capability).
    HiveAtAccessLog? accessLog;
    if (config.enableAccessLog) {
      final accessLogKeyStore = AccessLogKeyStore(atSign);
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
    //    log lives inside the keystore: every write appends to
    //    it for sync. Server-side bundles always have one;
    //    client-side bundles (no enableCommitId flag at all) may
    //    not, in which case keyValueStore.commitLog is null.
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
