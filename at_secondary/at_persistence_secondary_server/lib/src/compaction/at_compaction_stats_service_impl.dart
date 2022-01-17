import 'dart:convert';
import 'dart:core';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

class AtCompactionStatsServiceImpl implements AtCompactionStatsService {

  AtCompactionStatsServiceImpl(this.atLogType, this.keyStore) {
    _getKey();
  }

  late AtLogType atLogType;
  late String compactionStatsKey;
  late var keyStore;
  final _logger = AtSignLogger("AtCompactionStats");

  ///inserts empty statistics into the keystore at secondary intitalization
  Future<void> _insertInitialStats() async {
    try {
      await keyStore?.put(compactionStatsKey, AtData()..data = json.encode({}));
    } on Exception catch (_, e) {
      _logger.severe(e);
    }
  }

  ///stores statistics encoded as json in the keystore
  @override
  Future<void> handleStats(atCompactionStats) async {
    _logger.finer(atCompactionStats.toString());
    try {
      await keyStore?.put(compactionStatsKey,
          AtData()..data = json.encode(atCompactionStats.toJson()));
    } on Exception catch (_, e) {
      _logger.severe(e);
    }
  }

  ///changes the value of [compactionStatsKey] to match the AtLogType being processed
  void _getKey() {
    if (atLogType is AtCommitLog) compactionStatsKey = commitLogCompactionKey;

    if (atLogType is AtAccessLog) compactionStatsKey = accessLogCompactionKey;

    if (atLogType is AtNotificationKeystore)
      compactionStatsKey = notificationCompactionKey;
  }
}
