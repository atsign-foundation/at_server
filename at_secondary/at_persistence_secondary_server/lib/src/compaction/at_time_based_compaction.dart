import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class TimeBasedCompaction implements AtCompactionStrategy {
  late int timeInDays;
  int? compactionPercentage;

  TimeBasedCompaction(int time, int? compactionPercentage) {
    timeInDays = time;
    this.compactionPercentage = compactionPercentage;
  }

  @override
  void performCompaction(AtLogType atLogType) {
    var expiredKeys = atLogType.getExpired(timeInDays);
    if (expiredKeys == null) {
      return;
    }
    // If expired keys is empty, log compaction is not performed.
    if (expiredKeys.isEmpty) {
      return;
    }
    // Delete expired keys
    atLogType.delete(expiredKeys);
  }
}
