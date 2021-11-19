import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_logger.dart';

/// Implements the [AtCompactionObserver]
class AtCompactionObserverImpl implements AtCompactionObserver {
  late AtLogType atLogType;
  int compactionStartTimeInEpoch = 0;
  int sizeBeforeCompaction = 0;

  var keyStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign)!
      .getSecondaryKeyStore();

  final _logger = AtSignLogger('AtCompactionObserverImpl');

  AtCompactionObserverImpl(this.atLogType) {
    // Gets the key from secondary keystore.
    // If key is found, retrieves the previousRun value and add to compactionStats;
    // Else inserts a new key.
    keyStore!.get(_getKey()).catchError((onError) {
      _logger.finer('${_getKey()} not found in keystore. Inserting a new key.');
    }).then((atData) => _insertInitialStats(atData));
  }

  void _insertInitialStats(atData) {
    var compactionStats = CompactionStats()
      ..nextRun = DateTime.now()
          .toUtc()
          .add(Duration(minutes: _getCompactionFrequencyMins()));
    if (atData != null && atData.data != null) {
      var previousRun = (jsonDecode(atData.data))['previousRun'];
      if (previousRun != null && previousRun != 'null') {
        compactionStats.previousRun = DateTime.parse(previousRun).toUtc();
      }
    }
    var value = AtData()..data = jsonEncode(compactionStats);
    keyStore!.put(_getKey(), value);
  }

  /// Invoked when compaction process starts. Records the compaction start time and
  /// entries before the compaction.
  @override
  void start() {
    compactionStartTimeInEpoch = DateTime.now().toUtc().millisecondsSinceEpoch;
    sizeBeforeCompaction = atLogType.getSize();
  }

  /// Invokes when compaction process ends. Records the compaction end time and
  /// entries after the compaction.
  @override
  Future<void> end() async {
    int compactionEndTimeInEpoch =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    var compactionStats = CompactionStats()
      ..previousRun =
          DateTime.fromMillisecondsSinceEpoch(compactionEndTimeInEpoch)
      ..duration = DateTime.fromMillisecondsSinceEpoch(compactionEndTimeInEpoch)
          .difference(
              DateTime.fromMillisecondsSinceEpoch(compactionStartTimeInEpoch))
      ..keysBeforeCompaction = sizeBeforeCompaction
      ..keysAfterCompaction = atLogType.getSize()
      ..nextRun = DateTime.fromMillisecondsSinceEpoch(compactionEndTimeInEpoch)
          .add(Duration(minutes: _getCompactionFrequencyMins()));
    await keyStore!
        .put(_getKey(), AtData()..data = jsonEncode(compactionStats));
  }

  String _getKey() {
    if (atLogType is AtCommitLog) {
      return commitLogCompactionKey;
    }
    if (atLogType is AtAccessLog) {
      return accessLogCompactionKey;
    }
    return '';
  }

  int _getCompactionFrequencyMins() {
    if (atLogType is AtCommitLog) {
      return AtSecondaryConfig.commitLogCompactionFrequencyMins!;
    }
    if (atLogType is AtAccessLog) {
      return AtSecondaryConfig.accessLogCompactionFrequencyMins!;
    }
    return 0;
  }
}

/// Class represents the [AtLogType] compaction metrics.
class CompactionStats {
  DateTime? previousRun;
  DateTime? nextRun;
  Duration duration = Duration();
  int keysBeforeCompaction = 0;
  int keysAfterCompaction = 0;

  Map toJson() => {
        'previousRun': previousRun.toString(),
        'NextRun': nextRun.toString(),
        'duration(inMilliSeconds)': duration.inMilliseconds.toString(),
        'keysBeforeCompaction': keysBeforeCompaction,
        'keysAfterCompaction': keysAfterCompaction
      };

  CompactionStats fromJson(Map json) {
    previousRun = json['previousRun'] != null
        ? DateTime.parse(json['previousRun'])
        : null;
    nextRun = json['nextRun'] != null ? DateTime.parse(json['nextRun']) : null;
    duration = json['duration'] != null
        ? Duration(milliseconds: int.parse(json['duration']))
        : Duration();
    keysBeforeCompaction = json['keysBeforeCompaction'];
    keysAfterCompaction = json['keysAfterCompaction'];
    return this;
  }
}
