import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_secondary/src/compaction/at_compaction_stats_service_impl.dart';
import 'package:test/test.dart';

/// Unit-tests for [AtCompactionStatsService] — the
/// at_secondary-shaped sink that persists per-compaction-pass
/// metrics as atKeys in the keystore. The compaction itself is
/// exercised on each resource's `compact()` method in
/// `at_persistence_secondary_server/test/at_compaction_test.dart`.

const _atSign = '@alice';
final _storageDir = '${Directory.current.path}/test/hive_compaction_stats';

late HiveAtPersistenceFactory _factory;
late HiveAtPersistenceBundle _bundle;
late AtKeyValueStore _keyValueStore;
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
  _keyValueStore = _bundle.keyValueStore;
  _commitLog = _bundle.keyValueStore.commitLog! as HiveAtCommitLog;
  _accessLog = _bundle.accessLog!;
  _notificationKeystore = _bundle.notificationKeystore!;
}

Future<void> _teardown() async {
  await _factory.close();
  final dir = Directory(_storageDir);
  if (dir.existsSync()) await dir.delete(recursive: true);
}

/// Drain a compact() stream, return the count.
Future<int> _runCompaction(Compactable resource) async {
  var count = 0;
  await for (final _ in resource.compact(false)) {
    count++;
  }
  return count;
}

void main() {
  group('A group of tests related to commit log compaction stats', () {
    setUp(_bootstrap);
    tearDown(_teardown);

    test('verify commitLog stats in keystore', () async {
      await _commitLog.commit('@alice:phone@alice', CommitOp.UPDATE);
      await _commitLog.commit('@alice:phone@alice', CommitOp.UPDATE);
      final start = DateTime.timestamp();
      final count = await _runCompaction(_commitLog);
      final duration = DateTime.timestamp().difference(start);

      await AtCompactionStatsService(_keyValueStore).record(
        label: 'commitLog',
        start: start,
        compactedCount: count,
        duration: duration,
      );

      final atData =
          await _keyValueStore.get(AtConstants.commitLogCompactionKey);
      final decoded = jsonDecode(atData!.data!) as Map;
      expect(decoded['deletedKeysCount'], count.toString());
      expect(decoded['atCompactionType'], 'commitLog');
      expect(int.parse(decoded['compactionDurationInMills']) >= 0, isTrue);
    });
  });

  group('A group of tests related to access log compaction stats', () {
    setUp(_bootstrap);
    tearDown(_teardown);

    test('verify accessLog stats in keystore', () async {
      await _accessLog.insert('@alice', 'from');
      await _accessLog.insert('@alice', 'pol');
      await _accessLog.insert('@alice', 'scan');
      await _accessLog.insert('@alice', 'lookup',
          lookupKey: '@alice:phone@bob');
      final start = DateTime.timestamp();
      final count = await _runCompaction(_accessLog);
      final duration = DateTime.timestamp().difference(start);

      await AtCompactionStatsService(_keyValueStore).record(
        label: 'accessLog',
        start: start,
        compactedCount: count,
        duration: duration,
      );
      final atData =
          await _keyValueStore.get(AtConstants.accessLogCompactionKey);
      final decoded = jsonDecode(atData!.data!) as Map;
      expect(decoded['deletedKeysCount'], count.toString());
      expect(decoded['atCompactionType'], 'accessLog');
    });
  });

  group('A group of tests for Notification keystore compaction stats', () {
    setUp(_bootstrap);
    tearDown(_teardown);

    test('verify notificationKeyStore stats in keystore', () async {
      final start = DateTime.now();
      await AtCompactionStatsService(_keyValueStore).record(
        label: 'notificationKeystore',
        start: start,
        compactedCount: 239,
        duration: Duration(milliseconds: 2000),
      );
      final atData =
          await _keyValueStore.get('privatekey:notificationCompactionStats');
      final decoded = jsonDecode(atData!.data!) as Map;
      expect(decoded['deletedKeysCount'].toString(), '239');
      expect(decoded['compactionDurationInMills'].toString(), '2000');
      // Sanity reference: _notificationKeystore exists for setup.
      expect(_notificationKeystore, isNotNull);
    });
  });

  group('Per-resource persistence key selection', () {
    test('label-to-key map covers all three resources', () {
      expect(AtCompactionStatsService.labelToKey['commitLog'],
          AtConstants.commitLogCompactionKey);
      expect(AtCompactionStatsService.labelToKey['accessLog'],
          AtConstants.accessLogCompactionKey);
      expect(AtCompactionStatsService.labelToKey['notificationKeystore'],
          AtConstants.notificationCompactionKey);
    });
  });
}
