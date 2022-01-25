import 'dart:convert';
import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';
import 'package:uuid/uuid.dart';

Future<void> main() async {
  var storageDir = Directory.current.path + '/test/hive';
  AtAccessLog? atAccessLog = await AtAccessLogManagerImpl.getInstance()
      .getAccessLog('@alice', accessLogPath: storageDir);
  AtCommitLog? atCommitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice', commitLogPath: storageDir);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice');
  var persistenceManager =
      secondaryPersistenceStore!.getHivePersistenceManager();
  await persistenceManager!.init(storageDir);
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  hiveKeyStore?.commitLog = atCommitLog;
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager?.keyStore = hiveKeyStore;
  var keyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  var notificationKeyStoreInstance = AtNotificationKeystore.getInstance();
  notificationKeyStoreInstance.currentAtSign = '@alice';
  await notificationKeyStoreInstance.init('$storageDir/${Uuid().v4()}');

  late AtCompactionStatsServiceImpl atCompactionStatsServiceImpl;

  test("verify accessLog stats in keystore", () async {
    AtCompactionStats atCompactionStats = AtCompactionStats();
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atAccessLog!, keyStore);
    atCompactionStats.compactionDuration = Duration(minutes: 12);
    atCompactionStats.deletedKeysCount = 77;
    atCompactionStats.lastCompactionRun = DateTime.now();
    atCompactionStats.sizeAfterCompaction = 39;
    atCompactionStats.sizeBeforeCompaction = 69;
    atCompactionStats.compactionType = CompactionType.TimeBasedCompaction;
    await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
    AtData? atData = await keyStore?.get('privatekey:accessLogCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect(decodedData["deleted_keys_count"].toString(), '77');
    expect(decodedData["size_after_compaction"].toString(), '39');
    expect(decodedData["size_before_compaction"].toString(), '69');
    expect(
        decodedData["duration"].toString(), Duration(minutes: 12).toString());
    expect(decodedData['compaction_type'].toString(),
        CompactionType.TimeBasedCompaction.toString());
  });

  test("verify commitLog stats in keystore", () async {
    AtCompactionStats atCompactionStats = AtCompactionStats();
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atCommitLog!, keyStore);
    atCompactionStats.compactionDuration = Duration(minutes: 10);
    atCompactionStats.deletedKeysCount = 23;
    atCompactionStats.lastCompactionRun = DateTime.now();
    atCompactionStats.sizeAfterCompaction = 32;
    atCompactionStats.sizeBeforeCompaction = 44;
    atCompactionStats.compactionType = CompactionType.SizeBasedCompaction;
    await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
    AtData? atData = await keyStore?.get('privatekey:commitLogCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect(decodedData["deleted_keys_count"].toString(), '23');
    expect(decodedData["size_after_compaction"].toString(), '32');
    expect(decodedData["size_before_compaction"].toString(), '44');
    expect(
        decodedData["duration"].toString(), Duration(minutes: 10).toString());
    expect(decodedData['compaction_type'].toString(),
        CompactionType.SizeBasedCompaction.toString());
  });

  test("verify notificationKeyStore stats in keystore", () async {
    AtCompactionStats atCompactionStats = AtCompactionStats();
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(notificationKeyStoreInstance, keyStore);
    atCompactionStats.compactionDuration = Duration(minutes: 36);
    atCompactionStats.deletedKeysCount = 239;
    atCompactionStats.lastCompactionRun = DateTime.now();
    atCompactionStats.sizeAfterCompaction = 302;
    atCompactionStats.sizeBeforeCompaction = 404;
    atCompactionStats.compactionType = CompactionType.SizeBasedCompaction;
    await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
    AtData? atData =
        await keyStore?.get('privatekey:notificationCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect(decodedData["deleted_keys_count"].toString(), '239');
    expect(decodedData["size_after_compaction"].toString(), '302');
    expect(decodedData["size_before_compaction"].toString(), '404');
    expect(
        decodedData["duration"].toString(), Duration(minutes: 36).toString());
    expect(decodedData['compaction_type'].toString(),
        CompactionType.SizeBasedCompaction.toString());
  });

  test("check commitLog compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atCommitLog!, keyStore);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:commitLogCompactionStats");
  });

  test("check accessLog compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atAccessLog!, keyStore);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:accessLogCompactionStats");
  });

  test("check notification compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(notificationKeyStoreInstance, keyStore);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:notificationCompactionStats");
  });
}
