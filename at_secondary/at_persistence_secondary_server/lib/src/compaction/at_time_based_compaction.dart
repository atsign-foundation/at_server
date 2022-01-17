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

  ///compaction runs at a specified frequency
  @override
  Future<AtCompactionStats> performCompaction(AtLogType atLogType) async {
    DateTime compactionStartTime = DateTime.now().toUtc();
    var expiredKeys = await atLogType.getExpired(timeInDays);
    // If expired keys is empty, log compaction is not performed.
    if (expiredKeys.isEmpty) {
      _logger.finer('No expired keys. skipping time compaction for $atLogType');
    }
    atCompactionStats = AtCompactionStats();
    atCompactionStats.sizeBeforeCompaction = atLogType.getSize();
    atCompactionStats.deletedKeysCount = expiredKeys.length;
    atCompactionStats.compactionType = CompactionType.TimeBasedCompaction;
    // Delete expired keys
    await atLogType.delete(expiredKeys);
    atCompactionStats.lastCompactionRun = DateTime.now().toUtc();
    atCompactionStats.sizeAfterCompaction = atLogType.getSize();
    atCompactionStats.compactionDuration =
        atCompactionStats.lastCompactionRun.difference(compactionStartTime);

    return atCompactionStats;
  }
}
