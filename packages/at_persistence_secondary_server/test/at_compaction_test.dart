import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:test/test.dart';

String storageDir = '${Directory.current.path}/test/hive';
SecondaryPersistenceStore? secondaryPersistenceStore;
AtCommitLog? atCommitLog;

Future<void> setUpMethod({bool enableCommitId = true}) async {
  String atSign = '@alice';
  // Initialize secondary persistent store
  secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atSign);
  // Initialize commit log
  atCommitLog = await AtCommitLogManagerImpl.getInstance().getCommitLog(atSign,
      commitLogPath: storageDir, enableCommitId: enableCommitId);
  secondaryPersistenceStore!.getSecondaryKeyStore()?.commitLog = atCommitLog;
  // Init the hive instances
  await secondaryPersistenceStore!
      .getHivePersistenceManager()!
      .init(storageDir);
}

void main() {
  group('A group of test to verify commit log compaction job on server', () {
    setUp(() async {
      await setUpMethod();
    });

    test(
        'A test to verify commit log compaction when there are duplicate entries',
        () async {
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      var atCompactionService = AtCompactionService.getInstance();
      await atCompactionService.executeCompactionInternal(atCommitLog!);
      expect(atCommitLog!.entriesCount(), 1);
    });

    test(
        'A test to verify commit log compaction when there are no duplicate entries',
        () async {
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@bob:mobile@alice', CommitOp.UPDATE);
      var atCompactionService = AtCompactionService.getInstance();
      await atCompactionService.executeCompactionInternal(atCommitLog!);
      expect(atCommitLog!.entriesCount(), 2);
    });

    test('A test to verify duplicate entry with lowest commit id returned',
        () async {
      var firstEntryCommitId =
          await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog!.commit('@alice:phone@alice', CommitOp.UPDATE);
      List<int> keysToDelete = await atCommitLog!.getKeysToDeleteOnCompaction();
      expect(keysToDelete.length, 1);
      expect(keysToDelete.first, firstEntryCommitId);
    });

    tearDown(() async {
      await tearDownMethod();
    });
  });

  group('A group of test to verify commit log compaction job on client', () {
    setUp(() async {
      // Setting enableCommitId to false to replicate the client side commit log
      await setUpMethod(enableCommitId: false);
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
      var atCompactionService = AtCompactionService.getInstance();
      await atCompactionService.executeCompactionInternal(atCommitLog!);
      expect(atCommitLog!.entriesCount(), 2);
    });
    tearDown(() async => await tearDownMethod());
  });

  group('A group of test to verify access log compaction job', () {
    AtAccessLog? atAccessLog;
    setUp(() async {
      await setUpMethod();
      // Initialize commit log
      atAccessLog = await AtAccessLogManagerImpl.getInstance()
          .getAccessLog('@alice', accessLogPath: storageDir);
    });
    test('A test to verify access log compaction job', () async {
      await atAccessLog?.insert('@alice', 'from');
      await atAccessLog?.insert('@alice', 'pol');
      await atAccessLog?.insert('@alice', 'scan');
      await atAccessLog?.insert('@alice', 'lookup',
          lookupKey: '@alice:phone@bob');
      atAccessLog?.setCompactionConfig(
          AtCompactionConfig()..compactionPercentage = 99);
      var atCompactionService = AtCompactionService.getInstance();
      await atCompactionService.executeCompactionInternal(atAccessLog!);
      expect(atAccessLog?.entriesCount(), 1);
      AccessLogEntry? accessLogEntry =
          await atAccessLog?.getLastAccessLogEntry();
      expect(accessLogEntry?.fromAtSign, '@alice');
      expect(accessLogEntry?.lookupKey, '@alice:phone@bob');
      expect(accessLogEntry?.verbName, 'lookup');
    });
    tearDown(() async {
      await tearDownMethod();
    });
  });
}

Future<void> tearDownMethod() async {
  await SecondaryPersistenceStoreFactory.getInstance().close();
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory(storageDir).exists();
  if (isExists) {
    Directory(storageDir).deleteSync(recursive: true);
  }
}
