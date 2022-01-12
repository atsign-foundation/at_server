import 'dart:convert';
import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';

Future<void> main() async {

  var storageDir = Directory.current.path + '/test/hive';

  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice', commitLogPath: storageDir);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore('@alice');
  var persistenceManager = secondaryPersistenceStore!.getHivePersistenceManager();
  await persistenceManager!.init(storageDir);
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  hiveKeyStore?.commitLog = commitLogInstance;
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager?.keyStore = hiveKeyStore;
  var keyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  AtCommitLog? atCommitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice', commitLogPath: storageDir);

  AtCompactionStatsImpl.init('@alice');

  AtCompactionStatsImpl atCompactionStatsImpl = AtCompactionStatsImpl.getInstance(atCommitLog);

  test("check stats in keystore", () async {
    atCompactionStatsImpl.preCompaction();
    await atCompactionStatsImpl.postCompaction();
    AtData? atData = await keyStore?.get('privatekey:commitLogCompactionStats');
    var data = (atData?.data);
    var decodedData = jsonDecode(data!) as Map;
    expect("0", decodedData["deleted_keys_count"].toString());
    //expect(atCompactionStatsImpl.sizeBeforeCompaction.toString(), decodedData["size_before_compaction"].toString());
  });

  test("check compactionStats key", () async {
    atCompactionStatsImpl.preCompaction();
    expect("privatekey:commitLogCompactionStats", atCompactionStatsImpl.compactionStatsKey);
  });

  test("check duration calculation",() async {
    atCompactionStatsImpl.compactionStartTime = DateTime.now().toUtc().subtract(Duration(minutes: 5));
    await atCompactionStatsImpl.postCompaction();
    expect(Duration(minutes: 5).inMinutes, atCompactionStatsImpl.compactionDuration.inMinutes);
  });

  test("check value insertion into keystore", () async {
    await atCompactionStatsImpl.postCompaction();
    AtData? atData= await keyStore?.get('privatekey:commitLogCompactionStats');
    expect(jsonEncode(atCompactionStatsImpl), atData?.data);
  });

}

