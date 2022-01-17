import 'dart:convert';
import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';

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


  late AtCompactionStatsServiceImpl atCompactionStatsServiceImpl;

  test("check stats in keystore", () async {
    AtCompactionStats atCompactionStats = AtCompactionStats();
    atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(atAccessLog!, keyStore);
    atCompactionStats.compactionDuration = Duration(minutes: 10);
    atCompactionStats.deletedKeysCount = 23;
    atCompactionStats.lastCompactionRun = DateTime.now();
    atCompactionStats.sizeAfterCompaction = 32;
    atCompactionStats.sizeBeforeCompaction = 44;
    atCompactionStats.compactionType = CompactionType.TimeBasedCompaction;
    await atCompactionStatsServiceImpl.handleStats(atCompactionStats);
    AtData? atData = await keyStore?.get('privatekey:accessLogCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect('23', decodedData["deleted_keys_count"].toString());
    expect('32', decodedData["size_after_compaction"].toString());
    expect('44', decodedData["size_before_compaction"].toString());
    expect(atCompactionStats.compactionDuration.toString(), decodedData["duration"].toString());
    expect(CompactionType.TimeBasedCompaction.toString(), decodedData['compaction_type'.toString()]);

  });

  test("check compactionStats key", () async {
    atCompactionStatsServiceImpl = AtCompactionStatsServiceImpl(atCommitLog!, keyStore);
    expect("privatekey:commitLogCompactionStats",
        atCompactionStatsServiceImpl.compactionStatsKey);
  });
}
