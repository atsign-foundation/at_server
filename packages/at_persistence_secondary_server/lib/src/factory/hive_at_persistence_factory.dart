import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_secondary_keystore.dart';
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
    //    of the now-retired HivePersistenceManager).
    final keyStore = HiveSecondaryKeyStore(atSign);
    keyStore.commitLog = commitLog;
    await keyStore.init(config.storagePath);

    // 5. Compactors (optional capabilities). Each wraps the
    //    underlying log/keystore in a [HiveCompactionStrategy].
    final AtCompactionStrategy? commitLogCompactor =
        config.enableCommitLogCompactor
            ? HiveCompactionStrategy(commitLog)
            : null;
    final AtCompactionStrategy? accessLogCompactor =
        (config.enableAccessLogCompactor && accessLog != null)
            ? HiveCompactionStrategy(accessLog)
            : null;
    final AtCompactionStrategy? keyStoreCompactor =
        (config.enableKeyStoreCompactor && notificationKeystore != null)
            ? HiveCompactionStrategy(notificationKeystore)
            : null;

    final bundle = HiveAtPersistenceBundle._(
      atSign: atSign,
      keyStore: keyStore,
      commitLog: commitLog,
      accessLog: accessLog,
      notificationKeystore: notificationKeystore,
      commitLogCompactor: commitLogCompactor,
      accessLogCompactor: accessLogCompactor,
      keyStoreCompactor: keyStoreCompactor,
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

  @override
  // Typed at the concrete on HiveAtPersistenceBundle so [clear]
  // can reach the Hive-specific in-memory caches. The abstract
  // [AtPersistenceBundle.keyStore] still surfaces it as
  // SecondaryKeyStore<...>.
  @override
  final HiveSecondaryKeyStore keyStore;

  @override
  final HiveAtCommitLog commitLog;

  /// Nullable per the slim-bundle design: only populated when the
  /// config opts in via [HivePersistenceConfig.enableAccessLog].
  @override
  final HiveAtAccessLog? accessLog;

  /// Nullable per the slim-bundle design: only populated when the
  /// config opts in via [HivePersistenceConfig.enableNotificationKeystore].
  @override
  final HiveAtNotificationKeystore? notificationKeystore;

  @override
  final AtCompactionStrategy? commitLogCompactor;

  @override
  final AtCompactionStrategy? accessLogCompactor;

  @override
  final AtCompactionStrategy? keyStoreCompactor;

  bool _closed = false;

  HiveAtPersistenceBundle._({
    required this.atSign,
    required this.keyStore,
    required this.commitLog,
    required this.accessLog,
    required this.notificationKeystore,
    required this.commitLogCompactor,
    required this.accessLogCompactor,
    required this.keyStoreCompactor,
  });

  @override
  AtPersistenceBackendId get backendId => AtPersistenceBackendId.hive;

  @override
  void scheduleKeyExpireTask(int? runFrequencyMins,
      {Duration? runTimeInterval, bool skipCommits = false}) {
    keyStore.scheduleKeyExpireTask(runFrequencyMins,
        runTimeInterval: runTimeInterval, skipCommits: skipCommits);
  }

  @override
  Future<void> clear() async {
    if (_closed) {
      throw StateError(
          'Cannot clear a closed HiveAtPersistenceBundle for $atSign');
    }
    // Order: keystore, commit log, access log, notification keystore.
    // Caller-visible state and in-memory caches are reset; underlying
    // Hive boxes stay open for fast reuse in subsequent tests.
    await keyStore.clear();
    await commitLog.commitLogKeyStore.getBox().clear();
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
    await keyStore.close();
    await commitLog.close();
    accessLog
        ?.close(); // HiveAtAccessLog.close() returns void, not Future<void>
    await notificationKeystore?.close();
  }
}
