import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/compaction/at_compaction_stats_service_impl.dart';
import 'package:test/test.dart';

/// Unit-tests for [AtCompactionStatsServiceImpl] — the
/// at_secondary-shaped sink that persists [AtCompactionStats] as
/// atKeys in the keystore. The compaction itself is exercised by
/// [HiveCompactionStrategy] in
/// `at_persistence_secondary_server/test/at_compaction_test.dart`.

const _atSign = '@alice';
final _storageDir = '${Directory.current.path}/test/hive_compaction_stats';

late HiveAtPersistenceFactory _factory;
late HiveAtPersistenceBundle _bundle;
late SecondaryKeyStore _keyStore;
late HiveAtCommitLog _commitLog;
late HiveAtAccessLog _accessLog;
late HiveAtNotificationKeystore _notificationKeystore;

Future<void> _bootstrap() async {
  _factory = HiveAtPersistenceFactory();
  _bundle = await _factory.initialize(
    _atSign,
    HivePersistenceConfig(
      storagePath: _storageDir,
      commitLogPath: _storageDir,
      accessLogPath: _storageDir,
      notificationStoragePath: _storageDir,
    ),
  ) as HiveAtPersistenceBundle;
  _keyStore = _bundle.keyStore;
  _commitLog = _bundle.commitLog;
  _accessLog = _bundle.accessLog!;
  _notificationKeystore = _bundle.notificationKeystore!;
}

Future<void> _teardown() async {
  await _factory.close();
  final dir = Directory(_storageDir);
  if (dir.existsSync()) await dir.delete(recursive: true);
}

void main() {
  group('A group of tests related to commit log compaction', () {
    setUp(_bootstrap);
    tearDown(_teardown);

    test('verify commitLog stats in keystore', () async {
      await _commitLog.commit('@alice:phone@alice', CommitOp.UPDATE);
      await _commitLog.commit('@alice:phone@alice', CommitOp.UPDATE);
      final beforeMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
      final stats = await HiveCompactionStrategy(_commitLog).compact();
      final afterMicros = DateTime.now().toUtc().microsecondsSinceEpoch;

      expect(stats.preCompactionEntriesCount, 1);
      expect(stats.postCompactionEntriesCount, 1);
      expect(stats.compactionDurationInMills >= 0, true);
      expect(stats.compactionDurationInMills <= (afterMicros - beforeMicros),
          true);
      expect(
          stats.lastCompactionRun.microsecondsSinceEpoch > 0 &&
              stats.lastCompactionRun.microsecondsSinceEpoch <
                  DateTime.now().toUtc().microsecondsSinceEpoch,
          true);

      await AtCompactionStatsServiceImpl(_commitLog, _keyStore)
          .handleStats(stats);
      final atData = await _keyStore.get(AtConstants.commitLogCompactionKey);
      final decoded = jsonDecode(atData!.data!) as Map;
      expect(decoded['deletedKeysCount'], '0');
      expect(decoded['postCompactionEntriesCount'], '1');
      expect(decoded['preCompactionEntriesCount'], '1');
      expect(decoded['atCompactionType'], 'HiveAtCommitLog');
    });
  });

  group('A group of tests related to access log compaction', () {
    setUp(_bootstrap);
    tearDown(_teardown);

    test('verify accessLog stats in keystore', () async {
      await _accessLog.insert('@alice', 'from');
      await _accessLog.insert('@alice', 'pol');
      await _accessLog.insert('@alice', 'scan');
      await _accessLog.insert('@alice', 'lookup',
          lookupKey: '@alice:phone@bob');
      _accessLog
          .setCompactionConfig(AtCompactionConfig()..compactionPercentage = 99);
      final stats = await HiveCompactionStrategy(_accessLog).compact();
      await AtCompactionStatsServiceImpl(_accessLog, _keyStore)
          .handleStats(stats);
      final atData = await _keyStore.get(AtConstants.accessLogCompactionKey);
      final decoded = jsonDecode(atData!.data!) as Map;
      expect(decoded['deletedKeysCount'], '3');
      expect(decoded['postCompactionEntriesCount'], '1');
      expect(decoded['preCompactionEntriesCount'], '4');
    });
  });

  group('A group of tests for Notification keystore compaction', () {
    setUp(_bootstrap);
    tearDown(_teardown);

    test('verify notificationKeyStore stats in keystore', () async {
      final stats = AtCompactionStats()
        ..compactionDurationInMills = 2000
        ..deletedKeysCount = 239
        ..lastCompactionRun = DateTime.now()
        ..postCompactionEntriesCount = 302
        ..preCompactionEntriesCount = 404
        ..atCompactionType = _notificationKeystore.toString();
      await AtCompactionStatsServiceImpl(_notificationKeystore, _keyStore)
          .handleStats(stats);
      final atData =
          await _keyStore.get('privatekey:notificationCompactionStats');
      final decoded = jsonDecode(atData!.data!) as Map;
      expect(decoded[AtCompactionConstants.deletedKeysCount].toString(), '239');
      expect(
          decoded[AtCompactionConstants.postCompactionEntriesCount].toString(),
          '302');
      expect(
          decoded[AtCompactionConstants.preCompactionEntriesCount].toString(),
          '404');
      expect(
          decoded[AtCompactionConstants.compactionDurationInMills].toString(),
          '2000');
    });
  });

  group('compactionStatsKey selection', () {
    setUp(_bootstrap);
    tearDown(_teardown);

    test('commitLog -> commitLogCompactionStats', () async {
      expect(
          AtCompactionStatsServiceImpl(_commitLog, _keyStore)
              .compactionStatsKey,
          'privatekey:commitLogCompactionStats');
    });

    test('accessLog -> accessLogCompactionStats', () async {
      expect(
          AtCompactionStatsServiceImpl(_accessLog, _keyStore)
              .compactionStatsKey,
          'privatekey:accessLogCompactionStats');
    });

    test('notificationKeystore -> notificationCompactionStats', () async {
      expect(
          AtCompactionStatsServiceImpl(_notificationKeystore, _keyStore)
              .compactionStatsKey,
          'privatekey:notificationCompactionStats');
    });
  });
}
