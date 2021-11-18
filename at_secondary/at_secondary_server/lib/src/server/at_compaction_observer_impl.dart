import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';

/// Implements the [AtCompactionObserver]
class AtCompactionObserverImpl implements AtCompactionObserver {
  int compactionStartTimeInEpoch = 0;
  int sizeBeforeCompaction = 0;

  /// Invoked when compaction process starts. Records the compaction start time and
  /// entries before the compaction.
  @override
  void start(AtLogType atLogType) {
    compactionStartTimeInEpoch = DateTime.now().toUtc().millisecondsSinceEpoch;
    sizeBeforeCompaction = atLogType.getSize();
  }

  /// Invokes when compaction process ends. Records the compaction end time and
  /// entries after the compaction.
  @override
  Future<void> end(AtLogType atLogType) async {
    int compactionEndTimeInEpoch =
        DateTime.now().toUtc().millisecondsSinceEpoch;

    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(
            AtSecondaryServerImpl.getInstance().currentAtSign)!
        .getSecondaryKeyStore();

    int? compactionFrequencyMins;
    var key = '';
    // If atLogType is commitLog.
    if (atLogType is AtCommitLog) {
      key = 'privatekey:commitLogCompactionStats';
      compactionFrequencyMins =
          AtSecondaryConfig.commitLogCompactionFrequencyMins;
    }
    // If atLogType is AccessLog.
    if (atLogType is AtAccessLog) {
      key = 'privatekey:accessLogCompactionStats';
      compactionFrequencyMins =
          AtSecondaryConfig.accessLogCompactionFrequencyMins;
    }
    compactionFrequencyMins ??= 0;
    if (key.isNotEmpty) {
      // Build compaction stats
      var compactionStats = CompactionStats()
        ..previousRun =
            DateTime.fromMillisecondsSinceEpoch(compactionEndTimeInEpoch)
        ..duration = DateTime.fromMillisecondsSinceEpoch(
                compactionEndTimeInEpoch)
            .difference(
                DateTime.fromMillisecondsSinceEpoch(compactionStartTimeInEpoch))
        ..keysBeforeCompaction = sizeBeforeCompaction
        ..keysAfterCompaction = atLogType.getSize()
        ..nextRun =
            DateTime.fromMillisecondsSinceEpoch(compactionEndTimeInEpoch)
                .add(Duration(minutes: compactionFrequencyMins));

      await keyStore!.put(key, AtData()..data = jsonEncode(compactionStats));
    }
  }
}

/// Class represents the [AtLogType] compaction metrics.
class CompactionStats {
  late DateTime previousRun;
  late DateTime nextRun;
  late Duration duration;
  late int keysBeforeCompaction;
  late int keysAfterCompaction;

  Map toJson() => {
        'previousRun': previousRun.toString(),
        'NextRun': nextRun.toString(),
        'duration(inMilliSeconds)':
            duration.inMilliseconds.toString(),
        'keysBeforeCompaction': keysBeforeCompaction,
        'keysAfterCompaction': keysAfterCompaction
      };
}
