import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class TimeBasedCompaction implements AtCompactionStrategy {
  late int timeInDays;
  int? compactionPercentage;
  late AtCompactionStats atCompactionStats;
  final _logger = AtSignLogger('TimeBasedCompaction');

  TimeBasedCompaction(int time, this.compactionPercentage) {
    timeInDays = time;
  }

  ///Compaction procedure when compaction invocation criteria is time(frequency of compaction)
  ///Returns [AtCompactionStats] object with statistics calculated from pre and post compaction data
  @override
  Future<AtCompactionStats> performCompaction(AtLogType atLogType) async {
    DateTime compactionStartTime = DateTime.now().toUtc();
    var expiredKeys = await atLogType.getExpired(timeInDays);
    // If expired keys is empty, log compaction is not performed.
    if (expiredKeys.isEmpty) {
      _logger.finer('No expired keys. skipping time compaction for $atLogType');
    }
    atCompactionStats = AtCompactionStats();
    //collection of AtLogType statistics before compaction
    atCompactionStats.sizeBeforeCompaction = atLogType.getSize();
    atCompactionStats.deletedKeysCount = expiredKeys.length;
    atCompactionStats.compactionType = CompactionType.timeBasedCompaction;
    // Delete expired keys
    await atLogType.delete(expiredKeys);
    //collection of statistics post compaction
    atCompactionStats.lastCompactionRun = DateTime.now().toUtc();
    atCompactionStats.sizeAfterCompaction = atLogType.getSize();
    //calculation of compaction duration by comparing present time with compaction start time
    atCompactionStats.compactionDuration =
        atCompactionStats.lastCompactionRun?.difference(compactionStartTime);

    return atCompactionStats;
  }
}
