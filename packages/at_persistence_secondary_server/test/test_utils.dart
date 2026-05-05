import 'dart:io';
import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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

final Map<String, HiveSecondaryKeyStore> _testKeyStores = {};

/// Returns the shared [HiveSecondaryKeyStore] for [atSign] in the
/// current test process. Construction is idempotent; the keystore
/// owns its own Hive box, encryption secret, and key-expiry cron
/// (call `init(storagePath)` to open the box).
HiveSecondaryKeyStore testKeyStoreFor(String atSign) =>
    _testKeyStores.putIfAbsent(atSign, () => HiveSecondaryKeyStore(atSign));

/// Closes every test-shared keystore.
Future<void> closeTestPersistenceStores() async {
  for (final ks in _testKeyStores.values) {
    await ks.close();
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
    await log.close();
  }
  _testAccessLogs.clear();
}

// =====================================================================
// Composite helpers — collapse the common 3-step setUp boilerplate
// (commit log + keystore init + commit-log wiring) into a single call.
// Most test files use these via a thin per-file `setUpFunc` wrapper.
// =====================================================================

/// Initialises a per-atSign [HiveSecondaryKeyStore] backed by the
/// given [storageDir], creates a matching [HiveAtCommitLog], wires
/// the commit log onto the keystore, and returns the keystore.
///
/// Idempotent: subsequent calls for the same atSign return the
/// already-initialised instance. Pair with [tearDownTestPersistence]
/// in a tearDown to close everything and wipe the dir.
Future<HiveSecondaryKeyStore> setUpTestKeyStore(
  String atSign, {
  required String storageDir,
  bool enableCommitId = true,
}) async {
  final commitLog = await testCommitLogFor(atSign,
      commitLogPath: storageDir, enableCommitId: enableCommitId);
  final keyStore = testKeyStoreFor(atSign);
  await keyStore.init(storageDir);
  keyStore.commitLog = commitLog;
  return keyStore;
}

/// Closes every test-shared keystore / commit log / access log
/// and wipes [storageDir] from disk. Pair with [setUpTestKeyStore]
/// in tearDown.
Future<void> tearDownTestPersistence({String? storageDir}) async {
  await closeTestPersistenceStores();
  await closeTestCommitLogs();
  await closeTestAccessLogs();
  if (storageDir != null) {
    try {
      await Directory(storageDir).delete(recursive: true);
    } on FileSystemException {
      // Already gone (concurrent tearDown, or never created). Fine.
    }
  }
}
