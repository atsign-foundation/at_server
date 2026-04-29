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

    // Phase 1 implementation: route through the existing singleton-based
    // managers so the legacy `SecondaryPersistenceStoreFactory.getInstance()`
    // / `AtCommitLogManagerImpl.getInstance()` / `AtAccessLogManagerImpl.getInstance()`
    // call sites in `at_secondary_server` and external consumers see the
    // SAME per-atSign instances as we do. Phase 5 of the plan will reverse
    // this — the singletons will delegate to a process-default
    // [HiveAtPersistenceFactory] — at which point the body of this method
    // can construct the parts directly.

    // 1. Commit log.
    final commitLog = (await AtCommitLogManagerImpl.getInstance().getCommitLog(
        atSign,
        commitLogPath: config.commitLogPath,
        enableCommitId: config.enableCommitId))!;

    // 2. Access log.
    final accessLog = (await AtAccessLogManagerImpl.getInstance()
        .getAccessLog(atSign, accessLogPath: config.accessLogPath))!;

    // 3. Notification keystore (no singleton; constructed per atSign).
    final notificationKeystore = AtNotificationKeystore(atSign);
    await notificationKeystore.init(config.notificationStoragePath);

    // 4. Hive persistence manager + secondary keystore + manager wrapper.
    final secondaryPersistenceStore = SecondaryPersistenceStoreFactory
        .getInstance()
        .getSecondaryPersistenceStore(atSign)!;
    final hivePm = secondaryPersistenceStore.getHivePersistenceManager()!;
    await hivePm.init(config.storagePath);

    final keyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
    keyStore.commitLog = commitLog;
    secondaryPersistenceStore.getSecondaryKeyStoreManager()!.keyStore =
        keyStore;

    await keyStore.initialize();

    final bundle = HiveAtPersistenceBundle._(
      atSign: atSign,
      keyStore: keyStore,
      commitLog: commitLog,
      accessLog: accessLog,
      notificationKeystore: notificationKeystore,
      hivePersistenceManager: hivePm,
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
    // Phase 1 wiring: this factory routes through the legacy
    // singletons, which still cache the same per-atSign instances we
    // just closed. Clear their maps (without re-closing) so callers
    // that still go through `*.getInstance()` see a clean state and
    // a fresh start can re-populate them. Phase 5 of the plan will
    // reverse the delegation; this block goes away then.
    AtCommitLogManagerImpl.getInstance().clear();
    AtAccessLogManagerImpl.getInstance().clear();
    SecondaryPersistenceStoreFactory.getInstance().clear();
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

  // Hive-internal: needed by [scheduleKeyExpireTask] and [close], but
  // intentionally NOT exposed on the bundle's public surface — every
  // caller uses the abstract [AtPersistenceBundle] interface.
  final HivePersistenceManager _hivePersistenceManager;

  bool _closed = false;

  HiveAtPersistenceBundle._({
    required this.atSign,
    required this.keyStore,
    required this.commitLog,
    required this.accessLog,
    required this.notificationKeystore,
    required HivePersistenceManager hivePersistenceManager,
  }) : _hivePersistenceManager = hivePersistenceManager;

  @override
  AtPersistenceBackendId get backendId => AtPersistenceBackendId.hive;

  @override
  void scheduleKeyExpireTask(int? runFrequencyMins,
      {Duration? runTimeInterval, bool skipCommits = false}) {
    _hivePersistenceManager.scheduleKeyExpireTask(runFrequencyMins,
        runTimeInterval: runTimeInterval, skipCommits: skipCommits);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Order is the inverse of [HiveAtPersistenceFactory.initialize]:
    // close the keystore-via-manager first (so any in-flight expiry
    // task observes a closed box), then logs and notifications.
    await _hivePersistenceManager.close();
    await commitLog.close();
    accessLog.close(); // AtAccessLog.close() returns void, not Future<void>
    await notificationKeystore.close();
  }
}
