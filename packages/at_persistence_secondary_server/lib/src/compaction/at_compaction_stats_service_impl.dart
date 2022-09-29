import 'dart:convert';
import 'dart:core';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:at_utils/at_logger.dart';

class AtCompactionStatsServiceImpl implements AtCompactionStatsService {
  late final SecondaryPersistenceStore _secondaryPersistenceStore;
  late HiveKeystore _keyStore;

  AtCompactionStatsServiceImpl(
      this._atCompaction, this._secondaryPersistenceStore) {
    _getKey();
    _keyStore = _secondaryPersistenceStore.getSecondaryKeyStore()!;
  }

  late AtCompaction _atCompaction;
  late String compactionStatsKey;
  late String atLogName;
  final _logger = AtSignLogger("AtCompactionStats");

  @override
  Future<void> handleStats(atCompactionStats) async {
    if (atCompactionStats != null) {
      _logger.finer('$_atCompaction: ${atCompactionStats?.toString()}');
      try {
        await _keyStore.put(compactionStatsKey,
            AtData()..data = json.encode(atCompactionStats?.toJson()));
      } on Exception catch (_, e) {
        _logger.severe(e);
      }
    }
  }

  ///changes the value of [compactionStatsKey] to match the AtLogType being processed
  void _getKey() {
    if (_atCompaction is AtCommitLog) {
      compactionStatsKey = commitLogCompactionKey;
    }
    if (_atCompaction is AtAccessLog) {
      compactionStatsKey = accessLogCompactionKey;
    }
    if (_atCompaction is AtNotificationKeystore) {
      compactionStatsKey = notificationCompactionKey;
    }
  }
}
