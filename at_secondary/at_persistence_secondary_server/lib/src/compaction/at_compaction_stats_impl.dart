import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

class AtCompactionStatsImpl implements AtCompactionStats {
  ///storing private constructor in private variable
  ///private constructor refers to the instance of this class(only created once)
  static final AtCompactionStatsImpl _singleton = AtCompactionStatsImpl._internal();

  AtCompactionStatsImpl._internal();

  ///returns the only object of [AtCompactionStatsImpl]
  factory AtCompactionStatsImpl.init(atSign) {
    _singleton.atSign = atSign;
    _singleton.keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(atSign)
        ?.getSecondaryKeyStore();
    return _singleton;
  }

  factory AtCompactionStatsImpl.getInstance(atLogType) {
   _singleton.atLogType = atLogType;
    return _singleton;
  }

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
    } on Exception catch (_, e) {
      _logger.severe(e);
    }
  }

  ///measures pre-compaction parameters which will be further used for reference
  @override
  void preCompaction() {
    sizeBeforeCompaction = atLogType.getSize();
    compactionStartTime = DateTime.now().toUtc();
    keysBeforeCompaction = atLogType.entriesCount();
    _getKey();
  }

  ///measures post-compaction parameters which are compared with [preCompaction] parameters
  @override
  Future<void> postCompaction() async {
    compactionDuration = DateTime.now().toUtc().difference(compactionStartTime);
    sizeAfterCompaction = atLogType.getSize();
    lastCompactionRun = DateTime.now().toUtc();
    deletedKeysCount = atLogType.entriesCount() - keysBeforeCompaction;
    try {
      ///stores statistics encoded as json in the keystore
      await keyStore?.put(compactionStatsKey, AtData()..data = json.encode(_singleton.toJson()));
    } on Exception catch (_, e){
      _logger.severe(e);
    }
  }

  ///changes the value of [compactionStatsKey] to match the AtLogType being processed
  void _getKey() {
    if (atLogType is AtCommitLog)compactionStatsKey = commitLogCompactionKey;

    if (atLogType is AtAccessLog) compactionStatsKey = accessLogCompactionKey;

    if (atLogType is AtNotificationKeystore) compactionStatsKey = notificationCompactionKey;

  }

  ///maps predefined keys to their values which will be ready to encode to json
  Map toJson()=> {
    'duration': compactionDuration.toString(),
    'size_before_compaction': sizeBeforeCompaction.toString(),
    'size_after_compaction': sizeAfterCompaction.toString(),
    'deleted_keys_count': deletedKeysCount.toString(),
    'last_compaction_run': lastCompactionRun.toString()
  };

}