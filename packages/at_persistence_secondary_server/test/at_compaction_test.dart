import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

String storageDir = '${Directory.current.path}/test/hive';
HiveAtCommitLog? atCommitLog;

Future<void> setUpFunc({bool enableCommitId = true}) async {
  final keyValueStore = await setUpTestKeyStore('@alice',
      storageDir: storageDir, enableCommitId: enableCommitId);
  atCommitLog = keyValueStore.commitLog as HiveAtCommitLog;
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
      await HiveCompactionStrategy(atCommitLog!).compact();
      expect(atCommitLog!.entriesCount(), 1);
    });

    test(
        'A test to verify commit log compaction when there are no duplicate entries',
        () async {
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@bob:mobile@alice', CommitOp.UPDATE);
      await HiveCompactionStrategy(atCommitLog!).compact();
      expect(atCommitLog!.entriesCount(), 2);
    });

    test('A test to verify duplicate entry with lowest commit id returned',
        () async {
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      List<int> keysToDelete = await atCommitLog!.getKeysToDeleteOnCompaction();
      expect(keysToDelete.length, 0);
    });

    tearDown(() async {
      await tearDownFunc();
    });
  });

  group('A group of test to verify commit log compaction job on client', () {
    setUp(() async {
      // Setting enableCommitId to false to replicate the client side commit log
      await setUpFunc(enableCommitId: false);
    });
    test(
        'A test to verify commit log compaction on the client side does not remove null values',
        () async {
      await atCommitLog!.commitLogKeyStore.add(
          CommitEntry('@bob:phone@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 1);
      await atCommitLog!.commitLogKeyStore.add(
          CommitEntry('@bob:phone@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 2);
      await atCommitLog!.commitLogKeyStore.add(
          CommitEntry('@bob:phone@alice', CommitOp.UPDATE, DateTime.now()));
      await HiveCompactionStrategy(atCommitLog!).compact();
      expect(atCommitLog!.entriesCount(), 2);
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of test to verify access log compaction job', () {
    HiveAtAccessLog? atAccessLog;
    setUp(() async {
      await setUpFunc();
      // Initialize commit log
      atAccessLog = await testAccessLogFor('@alice', accessLogPath: storageDir);
    });
    test('A test to verify access log compaction job', () async {
      await atAccessLog?.insert('@alice', 'from');
      await atAccessLog?.insert('@alice', 'pol');
      await atAccessLog?.insert('@alice', 'scan');
      await atAccessLog?.insert('@alice', 'lookup',
          lookupKey: '@alice:phone@bob');
      atAccessLog?.setCompactionConfig(
          AtCompactionConfig()..compactionPercentage = 99);
      await HiveCompactionStrategy(atAccessLog!).compact();
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
