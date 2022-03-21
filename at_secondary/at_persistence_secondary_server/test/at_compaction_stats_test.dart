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
        AtCompactionStatsServiceImpl(atAccessLog!, secondaryPersistenceStore);
    atCompactionStats.compactionDuration = Duration(minutes: 12);
    atCompactionStats.deletedKeysCount = 77;
    atCompactionStats.lastCompactionRun = DateTime.now();
    atCompactionStats.postCompactionEntriesCount = 39;
    atCompactionStats.preCompactionEntriesCount = 69;
    atCompactionStats.compactionType = CompactionType.timeBasedCompaction;
    await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
    AtData? atData = await keyStore?.get('privatekey:accessLogCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect(decodedData["deletedKeysCount"].toString(), '77');
    expect(decodedData["postCompactionEntriesCount"].toString(), '39');
    expect(decodedData["preCompactionEntriesCount"].toString(), '69');
    expect(
        decodedData["duration"].toString(), Duration(minutes: 12).toString());
    expect(decodedData['compactionType'].toString(),
        CompactionType.timeBasedCompaction.toString());
  });

  test("verify commitLog stats in keystore", () async {
    AtCompactionStats atCompactionStats = AtCompactionStats();
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atCommitLog!, secondaryPersistenceStore);
    atCompactionStats.compactionDuration = Duration(minutes: 10);
    atCompactionStats.deletedKeysCount = 23;
    atCompactionStats.lastCompactionRun = DateTime.now();
    atCompactionStats.postCompactionEntriesCount = 32;
    atCompactionStats.preCompactionEntriesCount = 44;
    atCompactionStats.compactionType = CompactionType.sizeBasedCompaction;
    await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
    AtData? atData = await keyStore?.get('privatekey:commitLogCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect(decodedData["deletedKeysCount"].toString(), '23');
    expect(decodedData["postCompactionEntriesCount"].toString(), '32');
    expect(decodedData["preCompactionEntriesCount"].toString(), '44');
    expect(
        decodedData["duration"].toString(), Duration(minutes: 10).toString());
    expect(decodedData['compactionType'].toString(),
        CompactionType.sizeBasedCompaction.toString());
  });

  test("verify notificationKeyStore stats in keystore", () async {
    AtCompactionStats atCompactionStats = AtCompactionStats();
    atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(
        notificationKeyStoreInstance, secondaryPersistenceStore);
    atCompactionStats.compactionDuration = Duration(minutes: 36);
    atCompactionStats.deletedKeysCount = 239;
    atCompactionStats.lastCompactionRun = DateTime.now();
    atCompactionStats.postCompactionEntriesCount = 302;
    atCompactionStats.preCompactionEntriesCount = 404;
    atCompactionStats.compactionType = CompactionType.sizeBasedCompaction;
    await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
    AtData? atData =
        await keyStore?.get('privatekey:notificationCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect(decodedData["deletedKeysCount"].toString(), '239');
    expect(decodedData["postCompactionEntriesCount"].toString(), '302');
    expect(decodedData["preCompactionEntriesCount"].toString(), '404');
    expect(
        decodedData["duration"].toString(), Duration(minutes: 36).toString());
    expect(decodedData['compactionType'].toString(),
        CompactionType.sizeBasedCompaction.toString());
  });

  test("check commitLog compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atCommitLog!, secondaryPersistenceStore);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:commitLogCompactionStats");
  });

  test("check accessLog compactionStats key", () async {
    atCompactionStatsServiceImpl =
        AtCompactionStatsServiceImpl(atAccessLog!, secondaryPersistenceStore);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:accessLogCompactionStats");
  });

  test("check notification compactionStats key", () async {
    atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(
        notificationKeyStoreInstance, secondaryPersistenceStore);

    expect(atCompactionStatsServiceImpl.compactionStatsKey,
        "privatekey:notificationCompactionStats");
  });
}
