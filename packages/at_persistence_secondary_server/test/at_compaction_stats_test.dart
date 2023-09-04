import 'dart:convert';
import 'dart:io';
import 'package:at_commons/at_commons.dart' as at_commons;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

String storageDir = '${Directory.current.path}/test/hive';
SecondaryPersistenceStore? secondaryPersistenceStore;
AtCommitLog? atCommitLog;
AtAccessLog? atAccessLog;
late AtNotificationKeystore atNotificationKeystore;

late AtCompactionStatsServiceImpl atCompactionStatsServiceImpl;

Future<void> setUpMethod() async {
  // Initialize secondary persistent store
  secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice');
  // Initialize commit log
  atCommitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice', commitLogPath: storageDir, enableCommitId: true);
  // Initialize access log
  atAccessLog = await AtAccessLogManagerImpl.getInstance()
      .getAccessLog('@alice', accessLogPath: storageDir);
  secondaryPersistenceStore!.getSecondaryKeyStore()?.commitLog = atCommitLog;

  AtKeyServerMetadataStoreImpl atKeyMetadataStoreImpl =
      AtKeyServerMetadataStoreImpl('@alice');
  await atKeyMetadataStoreImpl.init(storageDir);
  (secondaryPersistenceStore!.getSecondaryKeyStore()!.commitLog as AtCommitLog).commitLogKeyStore.atKeyMetadataStore =
      atKeyMetadataStoreImpl;
  // AtNotification Keystore
  atNotificationKeystore = AtNotificationKeystore.getInstance();
  atNotificationKeystore.currentAtSign = '@alice';
  await atNotificationKeystore.init('$storageDir/${Uuid().v4()}');
  // Init the hive instances
  await secondaryPersistenceStore!
      .getHivePersistenceManager()!
      .init(storageDir);
}

Future<void> main() async {
  group('A group of tests related commit log compaction', () {
    setUp(() async {
      await setUpMethod();
      atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(
          atCommitLog!, secondaryPersistenceStore!);
    });

    test("verify commitLog stats in keystore", () async {
      // Add CommitEntries to CommitLog
      await atCommitLog?.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog?.commit('@alice:phone@alice', CommitOp.UPDATE);
      var atCompactionService = AtCompactionService.getInstance();
      int dateTimeBeforeCompactionInMilliSeconds =
          DateTime.now().toUtc().microsecondsSinceEpoch;
      // Run Compaction
      AtCompactionStats atCompactionStats =
          await atCompactionService.executeCompaction(atCommitLog!);

      int dateTimeAfterCompactionInMilliSeconds =
          DateTime.now().toUtc().microsecondsSinceEpoch;

      // Assertions
      expect(atCompactionStats.preCompactionEntriesCount, 1);
      expect(atCompactionStats.postCompactionEntriesCount, 1);
      expect(atCompactionStats.compactionDurationInMills > 0, true);
      expect(
          atCompactionStats.compactionDurationInMills <
              (dateTimeAfterCompactionInMilliSeconds -
                  dateTimeBeforeCompactionInMilliSeconds),
          true);
      expect(
          (atCompactionStats.lastCompactionRun.millisecondsSinceEpoch > 0 &&
              atCompactionStats.lastCompactionRun.millisecondsSinceEpoch <
                  DateTime.now().toUtc().millisecondsSinceEpoch),
          true);

      // Store Compaction Stats
      await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
      // Get Compaction Stats
      AtData? atData = await secondaryPersistenceStore!
          .getSecondaryKeyStore()
          ?.get(at_commons.commitLogCompactionKey);

      // Assert Compaction Stats
      var decodedData = jsonDecode(atData!.data!) as Map;
      expect(decodedData['deletedKeysCount'], '0');
      expect(decodedData['postCompactionEntriesCount'], '1');
      expect(decodedData['preCompactionEntriesCount'], '1');
      expect(decodedData['atCompactionType'], 'AtCommitLog');
    }, skip: 'Change in compaction impl');

    tearDown(() async => await tearDownMethod());
  });

  group('A group of tests related to access log compaction', () {
    setUp(() async {
      await setUpMethod();
      atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(
          atAccessLog!, secondaryPersistenceStore!);
    });

    test("verify accessLog stats in keystore", () async {
      await atAccessLog?.insert('@alice', 'from');
      await atAccessLog?.insert('@alice', 'pol');
      await atAccessLog?.insert('@alice', 'scan');
      await atAccessLog?.insert('@alice', 'lookup',
          lookupKey: '@alice:phone@bob');
      atAccessLog?.setCompactionConfig(
          AtCompactionConfig()..compactionPercentage = 99);
      var atCompactionService = AtCompactionService.getInstance();
      var atCompactionStats =
          await atCompactionService.executeCompaction(atAccessLog!);
      await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
      AtData? atData = await secondaryPersistenceStore!
          .getSecondaryKeyStore()
          ?.get(at_commons.accessLogCompactionKey);
      var data = (atData?.data);
      var decodedData = jsonDecode(data!) as Map;
      expect(decodedData["deletedKeysCount"], '3');
      expect(decodedData["postCompactionEntriesCount"], '1');
      expect(decodedData["preCompactionEntriesCount"], '4');
    });
    tearDown(() async => await tearDownMethod());
  });

  group('A group of tests for Notification keystore compaction', () {
    setUp(() async {
      await setUpMethod();
      atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(
          atNotificationKeystore, secondaryPersistenceStore!);
    });

    test("verify notificationKeyStore stats in keystore", () async {
      AtCompactionStats atCompactionStats = AtCompactionStats();
      atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(
          atNotificationKeystore, secondaryPersistenceStore!);
      atCompactionStats.compactionDurationInMills = 2000;
      atCompactionStats.deletedKeysCount = 239;
      atCompactionStats.lastCompactionRun = DateTime.now();
      atCompactionStats.postCompactionEntriesCount = 302;
      atCompactionStats.preCompactionEntriesCount = 404;
      atCompactionStats.atCompactionType = atNotificationKeystore.toString();
      await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
      AtData? atData = await secondaryPersistenceStore!
          .getSecondaryKeyStore()
          ?.get('privatekey:notificationCompactionStats');
      var data = (atData?.data);
      var decodedData = jsonDecode(data!) as Map;
      expect(decodedData[AtCompactionConstants.deletedKeysCount].toString(),
          '239');
      expect(
          decodedData[AtCompactionConstants.postCompactionEntriesCount]
              .toString(),
          '302');
      expect(
          decodedData[AtCompactionConstants.preCompactionEntriesCount]
              .toString(),
          '404');
      expect(
          decodedData[AtCompactionConstants.compactionDurationInMills]
              .toString(),
          '2000');
    });

    tearDown(() async => await tearDownMethod());
  });

  test("check commitLog compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atCommitLog!, secondaryPersistenceStore!);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:commitLogCompactionStats");
  });

  test("check accessLog compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atAccessLog!, secondaryPersistenceStore!);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:accessLogCompactionStats");
  });

  test("check notification compactionStats key", () async {
    atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(
        atNotificationKeystore, secondaryPersistenceStore!);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:notificationCompactionStats");
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
