import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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

    // Bootstrap order mirrors AtSecondaryServerImpl._initializePersistentInstances
    // (the call site this factory is meant to replace).

    // 1. Commit log — server-side commit log unless caller asks otherwise.
    final AtCommitLog commitLog;
    if (config.enableCommitId) {
      final ks = CommitLogKeyStore(atSign);
      await ks.init(config.commitLogPath, isLazy: false);
      commitLog = AtCommitLog(ks);
    } else {
      final ks = ClientCommitLogKeyStore(atSign);
      await ks.init(config.commitLogPath, isLazy: false);
      commitLog = ClientAtCommitLog(ks);
    }

    // 2. Access log.
    final accessLogKeyStore = AccessLogKeyStore(atSign);
    await accessLogKeyStore.init(config.accessLogPath);
    final accessLog = AtAccessLog(accessLogKeyStore);

    // 3. Notification keystore.
    final notificationKeystore = AtNotificationKeystore(atSign);
    await notificationKeystore.init(config.notificationStoragePath);

    // 4. Hive persistence manager + secondary keystore + manager wrapper.
    //    The existing SecondaryPersistenceStore wires these three together;
    //    we use it directly so per-atSign caching by the legacy
    //    SecondaryPersistenceStoreFactory and us stays consistent
    //    while Phase 1 migrations are in flight (Phase 5 of the plan
    //    will route the legacy factory through us).
    final secondaryPersistenceStore = SecondaryPersistenceStore(atSign);
    final hivePm = secondaryPersistenceStore.getHivePersistenceManager()!;
    await hivePm.init(config.storagePath);

    final secondaryKeyStoreManager =
        secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
    final keyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
    keyStore.commitLog = commitLog;
    secondaryKeyStoreManager.keyStore = keyStore;

    await keyStore.initialize();

    final bundle = HiveAtPersistenceBundle._(
      atSign: atSign,
      keyStore: keyStore,
      commitLog: commitLog,
      accessLog: accessLog,
      notificationKeystore: notificationKeystore,
      hivePersistenceManager: hivePm,
      secondaryPersistenceStore: secondaryPersistenceStore,
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
  final SecondaryKeyStore<String, AtData?, AtMetaData?> keyStore;

  @override
  final AtCommitLog commitLog;

  @override
  final AtAccessLog accessLog;

  @override
  final AtNotificationKeystore notificationKeystore;

  /// The Hive persistence manager that owns the keystore's underlying
  /// box. Exposed so callers that still need
  /// [HivePersistenceManager.scheduleKeyExpireTask] semantics in a
  /// Hive-shaped way can reach it. Phase 2 will hide this once the
  /// callers move onto [scheduleKeyExpireTask] on the bundle.
  final HivePersistenceManager hivePersistenceManager;

  /// The legacy [SecondaryPersistenceStore] wrapper. Exposed for
  /// backward compatibility with existing call sites that take a
  /// `SecondaryPersistenceStore` argument (e.g. metrics, compaction
  /// jobs). New code should prefer the explicit fields on the bundle.
  final SecondaryPersistenceStore secondaryPersistenceStore;

  bool _closed = false;

  HiveAtPersistenceBundle._({
    required this.atSign,
    required this.keyStore,
    required this.commitLog,
    required this.accessLog,
    required this.notificationKeystore,
    required this.hivePersistenceManager,
    required this.secondaryPersistenceStore,
  });

  @override
  AtPersistenceBackendId get backendId => AtPersistenceBackendId.hive;

  @override
  void scheduleKeyExpireTask(int? runFrequencyMins,
      {Duration? runTimeInterval, bool skipCommits = false}) {
    hivePersistenceManager.scheduleKeyExpireTask(runFrequencyMins,
        runTimeInterval: runTimeInterval, skipCommits: skipCommits);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Order is the inverse of [HiveAtPersistenceFactory.initialize]:
    // close the keystore-via-manager first (so any in-flight expiry
    // task observes a closed box), then logs and notifications.
    await hivePersistenceManager.close();
    await commitLog.close();
    accessLog.close(); // AtAccessLog.close() returns void, not Future<void>
    await notificationKeystore.close();
  }
}
