import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

String storageDir = '${Directory.current.path}/test/hive';
HiveAtCommitLog? atCommitLog;

Future<void> setUpFunc() async {
  final keyValueStore =
      await setUpTestKeyStore('@alice', storageDir: storageDir);
  atCommitLog = keyValueStore.commitLog as HiveAtCommitLog;
}

/// Drain a compact() stream, return the count of items yielded.
Future<int> _runCompaction(Compactable resource) async {
  var count = 0;
  await for (final _ in resource.compact(false)) {
    count++;
  }
  return count;
}

void main() {
  group('A group of test to verify commit log compaction job on server', () {
    setUp(() async {
      await setUpFunc();
    });

    test(
        'A test to verify commit log compaction when there are duplicate entries',
        () async {
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await _runCompaction(atCommitLog!);
      expect(atCommitLog!.entriesCount(), 1);
    });

    test(
        'A test to verify commit log compaction when there are no duplicate entries',
        () async {
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@bob:mobile@alice', CommitOp.UPDATE);
      await _runCompaction(atCommitLog!);
      expect(atCommitLog!.entriesCount(), 2);
    });

    test('A test to verify dryRun does not mutate the store', () async {
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@bob:mobile@alice', CommitOp.UPDATE);
      final preCount = atCommitLog!.entriesCount();
      final dryRunItems = await atCommitLog!.compact(true).toList();
      expect(atCommitLog!.entriesCount(), preCount,
          reason: 'dryRun should not mutate the store');
      // dryRun yields the same key-set a real run would; immediately
      // running the real compaction yields an equal-length set.
      final realItems = await atCommitLog!.compact(false).toList();
      expect(realItems.length, dryRunItems.length);
    });

    tearDown(() async {
      await tearDownFunc();
    });
  });

  group('A group of test to verify access log compaction job', () {
    HiveAtAccessLog? atAccessLog;
    setUp(() async {
      await setUpFunc();
      // Initialize access log with an aggressive compactionPercentage so
      // the test can drop nearly every entry in one pass.
      atAccessLog = await testAccessLogFor('@alice',
          accessLogPath: storageDir, compactionPercentage: 99);
    });
    test('A test to verify access log compaction job', () async {
      await atAccessLog?.insert('@alice', 'from');
      await atAccessLog?.insert('@alice', 'pol');
      await atAccessLog?.insert('@alice', 'scan');
      await atAccessLog?.insert('@alice', 'lookup',
          lookupKey: '@alice:phone@bob');
      await _runCompaction(atAccessLog!);
      expect(atAccessLog?.entriesCount(), 1);
      AccessLogEntry? accessLogEntry =
          await atAccessLog?.getLastAccessLogEntry();
      expect(accessLogEntry?.fromAtSign, '@alice');
      expect(accessLogEntry?.lookupKey, '@alice:phone@bob');
      expect(accessLogEntry?.verbName, 'lookup');
    });
    tearDown(() async {
      await tearDownFunc();
    });
  });
}

Future<void> tearDownFunc() => tearDownTestPersistence(storageDir: storageDir);
