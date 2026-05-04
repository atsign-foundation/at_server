import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_secondary_keystore.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_log_keystore.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_log_keystore.dart';

class TestUtils {
  static String generateRandomString(int length) {
    const charset =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }
}

// =====================================================================
// Test-side persistence helpers — direct replacements for the deprecated
// `SecondaryPersistenceStoreFactory.getInstance()` /
// `AtCommitLogManagerImpl.getInstance()` /
// `AtAccessLogManagerImpl.getInstance()` calls that were removed in 5.0.0.
// They share state across all tests in the process, mirroring the
// previous singleton behaviour without resurrecting the singleton API.
// =====================================================================

class _TestKeyStorePair {
  final HiveSecondaryKeyStore keyStore;
  final HivePersistenceManager manager;
  _TestKeyStorePair(this.keyStore, this.manager);
}

final Map<String, _TestKeyStorePair> _testKeyStores = {};

_TestKeyStorePair _pairFor(String atSign) =>
    _testKeyStores.putIfAbsent(atSign, () {
      final manager = HivePersistenceManager(atSign);
      final keyStore = HiveSecondaryKeyStore();
      keyStore.persistenceManager = manager;
      manager.keyStoreForExpireTask = keyStore;
      return _TestKeyStorePair(keyStore, manager);
    });

/// Returns the shared [HiveSecondaryKeyStore] for [atSign] in the
/// current test process. The associated [HivePersistenceManager]
/// is wired up internally; reach it via
/// [testHivePersistenceManagerFor].
HiveSecondaryKeyStore testKeyStoreFor(String atSign) =>
    _pairFor(atSign).keyStore;

/// Returns the shared [HivePersistenceManager] for [atSign] in the
/// current test process. Wired to the same [HiveSecondaryKeyStore]
/// returned by [testKeyStoreFor].
HivePersistenceManager testHivePersistenceManagerFor(String atSign) =>
    _pairFor(atSign).manager;

/// Closes every test-shared persistence manager.
Future<void> closeTestPersistenceStores() async {
  for (final pair in _testKeyStores.values) {
    await pair.manager.close();
  }
  _testKeyStores.clear();
}

final Map<String, HiveAtCommitLog> _testCommitLogs = {};

/// Returns the shared [HiveAtCommitLog] for [atSign] in the current
/// test process, creating it on first call. If [commitLogPath] is
/// supplied on the first call, the underlying box is opened at that
/// path. Subsequent calls return the cached instance regardless of
/// the path argument.
Future<HiveAtCommitLog> testCommitLogFor(
  String atSign, {
  String? commitLogPath,
  bool enableCommitId = true,
}) async {
  if (_testCommitLogs.containsKey(atSign)) return _testCommitLogs[atSign]!;
  final HiveAtCommitLog log;
  final CommitLogKeyStore ks;
  if (enableCommitId) {
    ks = CommitLogKeyStore(atSign);
    if (commitLogPath != null) await ks.init(commitLogPath, isLazy: false);
    log = HiveAtCommitLog(ks);
  } else {
    ks = ClientCommitLogKeyStore(atSign);
    if (commitLogPath != null) await ks.init(commitLogPath, isLazy: false);
    log = HiveClientAtCommitLog(ks);
  }
  _testCommitLogs[atSign] = log;
  return log;
}

/// Closes every test-shared [HiveAtCommitLog].
Future<void> closeTestCommitLogs() async {
  for (final log in _testCommitLogs.values) {
    await log.close();
  }
  _testCommitLogs.clear();
}

final Map<String, HiveAtAccessLog> _testAccessLogs = {};

/// Returns the shared [HiveAtAccessLog] for [atSign] in the current
/// test process, creating it on first call.
Future<HiveAtAccessLog> testAccessLogFor(
  String atSign, {
  String? accessLogPath,
}) async {
  if (_testAccessLogs.containsKey(atSign)) return _testAccessLogs[atSign]!;
  final ks = AccessLogKeyStore(atSign);
  if (accessLogPath != null) await ks.init(accessLogPath);
  final log = HiveAtAccessLog(ks);
  _testAccessLogs[atSign] = log;
  return log;
}

/// Closes every test-shared [HiveAtAccessLog].
Future<void> closeTestAccessLogs() async {
  for (final log in _testAccessLogs.values) {
    log.close();
  }
  _testAccessLogs.clear();
}
