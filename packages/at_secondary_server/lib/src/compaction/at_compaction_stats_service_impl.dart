import 'dart:convert';
import 'dart:core';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Persists compaction stats as atKeys in the secondary's keystore.
/// The atKey chosen depends on which log/store the stats came from
/// — see [_getKey]. This is the secondary-server-shaped policy: a
/// different deployment could implement [AtCompactionStatsService]
/// to push stats to Prometheus, drop them, etc.
class AtCompactionStatsServiceImpl implements AtCompactionStatsService {
  final AtKeyValueStore _keyStore;
  final AtCompaction _atCompaction;
  @visibleForTesting
  late String compactionStatsKey;
  final _logger = AtSignLogger("AtCompactionStats");

  AtCompactionStatsServiceImpl(this._atCompaction, this._keyStore) {
    _getKey();
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
    if (_atCompaction is HiveAtCommitLog) {
      compactionStatsKey = AtConstants.commitLogCompactionKey;
    }
    if (_atCompaction is HiveAtAccessLog) {
      compactionStatsKey = AtConstants.accessLogCompactionKey;
    }
    if (_atCompaction is HiveAtNotificationKeystore) {
      compactionStatsKey = AtConstants.notificationCompactionKey;
    }
  }
}
