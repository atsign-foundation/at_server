import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';

class AtCompactionStatsImpl implements AtCompactionStats{

  AtCompactionStatsImpl(this.atLogType);

  AtLogType atLogType;
  late DateTime compactionStartTime;
  late Duration compactionDuration;
  late int sizeBeforeCompaction;
  late int sizeAfterCompaction;
  var keyStore = SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(AtSecondaryServerImpl.getInstance().currentAtSign)?.getSecondaryKeyStore();

  @override
  void initialize(){
    sizeBeforeCompaction = atLogType.getSize();
    compactionStartTime = DateTime.now().toUtc();
  }

  @override
  void calculate(){
    compactionDuration = DateTime.now().toUtc().difference(compactionStartTime);
    sizeAfterCompaction = atLogType.getSize();
  }

  @override
  void writeStats(AtCompactionStats atCompactionStats) async {
    await keyStore?.put(commitLogCompactionKey, AtData()..data = json.encode(atCompactionStats));
  }

  Map toJson()=> {
    'Compaction Duration': compactionDuration.toString(),
    'Size before compaction': sizeBeforeCompaction.toString(),
    'Size after compaction': sizeAfterCompaction.toString()
  };


}