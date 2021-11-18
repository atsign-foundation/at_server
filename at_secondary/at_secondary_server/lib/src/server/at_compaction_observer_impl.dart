import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';

/// Implements the [At]
class AtCompactionObserverImpl implements AtCompactionObserver {
  int compactionStartTimeInEpoch = 0;
  int sizeBeforeCompaction = 0;

  @override
  void start(AtLogType atLogType) {
    compactionStartTimeInEpoch = DateTime.now().toUtc().millisecondsSinceEpoch;
    sizeBeforeCompaction = atLogType.getSize();
  }

  @override
  Future<void> end(AtLogType atLogType) async {
    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(
            AtSecondaryServerImpl.getInstance().currentAtSign)!
        .getSecondaryKeyStore();

    int compactionEndTimeInEpoch =
        DateTime.now().toUtc().millisecondsSinceEpoch;
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
        ..lastRan =
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

class CompactionStats {
  late DateTime lastRan;
  late DateTime nextRun;
  late Duration duration;
  late int keysBeforeCompaction;
  late int keysAfterCompaction;

  Map toJson() => {
        'compactionLastRan': lastRan.toString(),
        'compactionNextRun': nextRun.toString(),
        'compactionDuration(inMilliSeconds)':
            duration.inMilliseconds.toString(),
        'keysBeforeCompaction': keysBeforeCompaction,
        'keysAfterCompaction': keysAfterCompaction
      };
}
