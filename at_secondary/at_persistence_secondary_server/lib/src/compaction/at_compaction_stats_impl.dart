import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_logger.dart';

import '../../at_persistence_secondary_server.dart';

class AtCompactionStatsImpl implements AtCompactionStats{

  static final AtCompactionStatsImpl _singleton = AtCompactionStatsImpl._internal();

  AtCompactionStatsImpl._internal();

  factory AtCompactionStatsImpl.init(atSign){
    _singleton.atSign = atSign;
    _singleton.keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(atSign)
        ?.getSecondaryKeyStore();
    return _singleton;
  }

  factory AtCompactionStatsImpl.getInstance(atLogType){
   _singleton.atLogType = atLogType;
    return _singleton;
  }

  //AtCompactionStatsImpl.setLogType(this.atLogType);

  late String atSign;
  late AtLogType atLogType;
  late DateTime compactionStartTime;
  late Duration compactionDuration;
  late int sizeBeforeCompaction;
  late int sizeAfterCompaction;
  late String compactionStatsKey;
  late DateTime lastCompactionRun;
  late int keysBeforeCompaction;
  late int deletedKeysCount;
  var keyStore;
  final _logger = AtSignLogger("AtCompactionStats");

  Future<void> _insertInitialStats() async {
    try{
      await keyStore?.put(compactionStatsKey, AtData()..data = json.encode({}));
    }on Exception catch (_, e){
      _logger.severe(e);
    }
  }

  @override
  void initializeStats(){
    sizeBeforeCompaction = atLogType.getSize();
    compactionStartTime = DateTime.now().toUtc();
    keysBeforeCompaction = atLogType.entriesCount();
    _getKey();
  }

  @override
  void calculateStats(){
    compactionDuration = DateTime.now()
        .toUtc()
        .difference(compactionStartTime);
    sizeAfterCompaction = atLogType.getSize();
    lastCompactionRun = DateTime.now().toUtc();
    deletedKeysCount = atLogType.entriesCount() - keysBeforeCompaction;
  }

  @override
  Future<void> writeStats(AtCompactionStats atCompactionStats) async {
    try {
      await keyStore
          ?.put(compactionStatsKey, AtData()
        ..data = json.encode(atCompactionStats));
    }on Exception catch (_, e){
      _logger.severe(e);
    }
  }

  void _getKey(){
    if (atLogType is AtCommitLog){ compactionStatsKey = commitLogCompactionKey;

    if (atLogType is AtAccessLog) compactionStatsKey = accessLogCompactionKey;

    if (atLogType is AtNotificationKeystore) compactionStatsKey = notificationCompactionKey;
    }

  }

  Map toJson()=> {
    'Compaction Duration': compactionDuration.toString(),
    'Size before compaction': sizeBeforeCompaction.toString(),
    'Size after compaction': sizeAfterCompaction.toString(),
    'No. of deleted keys': deletedKeysCount.toString(),
    'Last compaction run': lastCompactionRun.toString()
  };


}