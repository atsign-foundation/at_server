import 'dart:convert';
import 'dart:io';
import 'package:at_commons/at_commons.dart' as at_commons;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

import 'test_utils.dart';
import 'package:uuid/uuid.dart';

String storageDir = '${Directory.current.path}/test/hive';
SecondaryKeyStore? keyStore;
HiveAtCommitLog? atCommitLog;
HiveAtAccessLog? atAccessLog;
late HiveAtNotificationKeystore atNotificationKeystore;

late AtCompactionStatsServiceImpl atCompactionStatsServiceImpl;

Future<void> setUpMethod() async {
  // Initialize secondary persistent store
  final secondaryPersistenceStore = testPersistenceStoreFor('@alice');
  // Initialize commit log
  atCommitLog = await testCommitLogFor('@alice',
      commitLogPath: storageDir, enableCommitId: true);
  // Initialize access log
  atAccessLog = await testAccessLogFor('@alice', accessLogPath: storageDir);
  keyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  keyStore!.commitLog = atCommitLog;
  // AtNotification Keystore
  atNotificationKeystore = HiveAtNotificationKeystore('@alice');
  await atNotificationKeystore.init('$storageDir/${Uuid().v4()}');
  // Init the hive instances
  await secondaryPersistenceStore.getHivePersistenceManager()!.init(storageDir);
}

Future<void> main() async {
  group('A group of tests related commit log compaction', () {
    setUp(() async {
      await setUpMethod();
      atCompactionStatsServiceImpl =
          AtCompactionStatsServiceImpl(atCommitLog!, keyStore!);
    });

    test("verify commitLog stats in keystore", () async {
      // Add CommitEntries to CommitLog
      await atCommitLog?.commit('@alice:phone@alice', CommitOp.UPDATE);
      await atCommitLog?.commit('@alice:phone@alice', CommitOp.UPDATE);
      var atCompactionService = AtCompactionService();
      int beforeMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
      // Run Compaction
      AtCompactionStats atCompactionStats =
          await atCompactionService.executeCompaction(atCommitLog!);

      int afterMicros = DateTime.now().toUtc().microsecondsSinceEpoch;

      // Assertions
      expect(atCompactionStats.preCompactionEntriesCount, 1);
      expect(atCompactionStats.postCompactionEntriesCount, 1);
      expect(atCompactionStats.compactionDurationInMills >= 0, true);
      expect(
          atCompactionStats.compactionDurationInMills <=
              (afterMicros - beforeMicros),
          true);
      expect(
          (atCompactionStats.lastCompactionRun.microsecondsSinceEpoch > 0 &&
              atCompactionStats.lastCompactionRun.microsecondsSinceEpoch <
                  DateTime.now().toUtc().microsecondsSinceEpoch),
          true);

      // Store Compaction Stats
      await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
      // Get Compaction Stats
      AtData? atData =
          await keyStore!.get(at_commons.AtConstants.commitLogCompactionKey);

      // Assert Compaction Stats
      var decodedData = jsonDecode(atData!.data!) as Map;
      expect(decodedData['deletedKeysCount'], '0');
      expect(decodedData['postCompactionEntriesCount'], '1');
      expect(decodedData['preCompactionEntriesCount'], '1');
      expect(decodedData['atCompactionType'], 'HiveAtCommitLog');
    });

    tearDown(() async => await tearDownMethod());
  });

  group('A group of tests related to access log compaction', () {
    setUp(() async {
      await setUpMethod();
      atCompactionStatsServiceImpl =
          AtCompactionStatsServiceImpl(atAccessLog!, keyStore!);
    });

    test("verify accessLog stats in keystore", () async {
      await atAccessLog?.insert('@alice', 'from');
      await atAccessLog?.insert('@alice', 'pol');
      await atAccessLog?.insert('@alice', 'scan');
      await atAccessLog?.insert('@alice', 'lookup',
          lookupKey: '@alice:phone@bob');
      atAccessLog?.setCompactionConfig(
          AtCompactionConfig()..compactionPercentage = 99);
      var atCompactionService = AtCompactionService();
      var atCompactionStats =
          await atCompactionService.executeCompaction(atAccessLog!);
      await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
      AtData? atData =
          await keyStore!.get(at_commons.AtConstants.accessLogCompactionKey);
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
      atCompactionStatsServiceImpl =
          AtCompactionStatsServiceImpl(atNotificationKeystore, keyStore!);
    });

    test("verify notificationKeyStore stats in keystore", () async {
      AtCompactionStats atCompactionStats = AtCompactionStats();
      atCompactionStatsServiceImpl =
          AtCompactionStatsServiceImpl(atNotificationKeystore, keyStore!);
      atCompactionStats.compactionDurationInMills = 2000;
      atCompactionStats.deletedKeysCount = 239;
      atCompactionStats.lastCompactionRun = DateTime.now();
      atCompactionStats.postCompactionEntriesCount = 302;
      atCompactionStats.preCompactionEntriesCount = 404;
      atCompactionStats.atCompactionType = atNotificationKeystore.toString();
      await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
      AtData? atData =
          await keyStore!.get('privatekey:notificationCompactionStats');
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
        AtCompactionStatsServiceImpl(atCommitLog!, keyStore!);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:commitLogCompactionStats");
  });

  test("check accessLog compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atAccessLog!, keyStore!);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:accessLogCompactionStats");
  });

  test("check notification compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atNotificationKeystore, keyStore!);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:notificationCompactionStats");
  });
}

Future<void> tearDownMethod() async {
  await closeTestPersistenceStores();
  await closeTestCommitLogs();
  await atNotificationKeystore.close();
  var isExists = await Directory(storageDir).exists();
  if (isExists) {
    Directory(storageDir).deleteSync(recursive: true);
  }
}
