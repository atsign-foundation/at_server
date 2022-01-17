import 'dart:convert';
import 'dart:core';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

class AtCompactionStatsServiceImpl implements AtCompactionStatsService {
  late var _keyStore;

  AtCompactionStatsServiceImpl(this.atLogType, [this._keyStore]) {
    _keyStore ??= SecondaryKeyStoreManager().getKeyStore();
    _getKey();
  }

  late AtLogType atLogType;
  late String _compactionStatsKey;
  final _logger = AtSignLogger("AtCompactionStats");

  ///stores statistics encoded as json in the keystore
  @override
  Future<void> handleStats(atCompactionStats) async {
    _logger.finer(atCompactionStats.toString());
    try {
      await _keyStore.put(_compactionStatsKey,
          AtData()..data = json.encode(atCompactionStats.toJson()));
    } on Exception catch (_, e) {
      _logger.severe(e);
    }
  }

  ///changes the value of [compactionStatsKey] to match the AtLogType being processed
  void _getKey() {
    if (atLogType is AtCommitLog) {
      _compactionStatsKey = commitLogCompactionKey;
    }
    if (atLogType is AtAccessLog) {
      _compactionStatsKey = accessLogCompactionKey;
    }
    if (atLogType is AtNotificationKeystore) {
      _compactionStatsKey = notificationCompactionKey;
    }
  }
}
