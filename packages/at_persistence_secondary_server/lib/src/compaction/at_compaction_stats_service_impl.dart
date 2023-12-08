import 'dart:convert';
import 'dart:core';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// An implementation class of [AtCompactionStatsService] to write the compaction
/// metrics to the [SecondaryKeyStore]
class AtCompactionStatsServiceImpl implements AtCompactionStatsService {
  late final SecondaryPersistenceStore _secondaryPersistenceStore;
  late HiveKeystore _keyStore;
  late final AtCompaction _atCompaction;
  @visibleForTesting
  late String compactionStatsKey;
  final _logger = AtSignLogger("AtCompactionStats");

  AtCompactionStatsServiceImpl(
      this._atCompaction, this._secondaryPersistenceStore) {
    _getKey();
    _keyStore = _secondaryPersistenceStore.getSecondaryKeyStore()!;
  }

  @override
  Future<void> handleStats(AtCompactionStats atCompactionStats) async {
    _logger.finest(
        'Completed compaction of $_atCompaction: ${atCompactionStats.toString()}');
    try {
      await _keyStore.put(compactionStatsKey,
          AtData()..data = json.encode(atCompactionStats.toJson()));
    } on Exception catch (_, e) {
      _logger.severe(e);
    }
  }

  ///changes the value of [compactionStatsKey] to match the AtLogType being processed
  void _getKey() {
    if (_atCompaction is AtCommitLog) {
      compactionStatsKey = AtConstants.commitLogCompactionKey;
    }
    if (_atCompaction is AtAccessLog) {
      compactionStatsKey = AtConstants.accessLogCompactionKey;
    }
    if (_atCompaction is AtNotificationKeystore) {
      compactionStatsKey = AtConstants.notificationCompactionKey;
    }
  }
}
