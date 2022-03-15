import 'dart:convert';
import 'dart:core';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

class AtCompactionStatsServiceImpl implements AtCompactionStatsService {
  late SecondaryPersistenceStore _secondaryPersistenceStore;
  late var _keyStore;

  AtCompactionStatsServiceImpl(
      this.atLogType, this._secondaryPersistenceStore) {
    _getKey();
    _keyStore = _secondaryPersistenceStore.getSecondaryKeyStore();
  }

  late AtLogType atLogType;
  late String compactionStatsKey;
  late String atLogName;
  final _logger = AtSignLogger("AtCompactionStats");

  @override
  Future<void> handleStats(atCompactionStats) async {
    if (atCompactionStats != null) {
      _logger.finer('$atLogName: ${atCompactionStats?.toString()}');
      try {
        await _keyStore.put(compactionStatsKey,
            AtData()..data = json.encode(atCompactionStats?.toJson()));
      } on Exception catch (_, e) {
        _logger.severe(e);
      }
    } else {
      _logger.finer(
          '$atLogName: compaction criteria not met, skipping data write into key store');
    }
  }

  ///changes the value of [compactionStatsKey] to match the AtLogType being processed
  void _getKey() {
    if (atLogType is AtCommitLog) {
      compactionStatsKey = commitLogCompactionKey;
      atLogName = 'commitLogCompaction';
    }
    if (atLogType is AtAccessLog) {
      compactionStatsKey = accessLogCompactionKey;
      atLogName = 'accessLogCompaction';
    }
    if (atLogType is AtNotificationKeystore) {
      compactionStatsKey = notificationCompactionKey;
      atLogName = 'notificationCompaction';
    }
  }
}
