import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class TimeBasedCompaction implements AtCompactionStrategy {
  int timeInDays;
  int compactionPercentage;

  TimeBasedCompaction(int time, int compactionPercentage) {
    timeInDays = time;
    this.compactionPercentage = compactionPercentage;
  }

  @override
  Future<void> performCompaction(AtLogType atLogType) async {
    var expiredKeys = await atLogType.getExpired(timeInDays);
    if (expiredKeys == null) {
      return;
    }
    // If expired keys is empty, log compaction is not performed.
    if (expiredKeys.isEmpty) {
      return;
    }
    // Delete expired keys
    await atLogType.remove(expiredKeys);
  }
}
