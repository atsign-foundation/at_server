import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class TimeBasedCompaction implements AtCompactionStrategy {
  late int timeInDays;
  int? compactionPercentage;

  final _logger = AtSignLogger('TimeBasedCompaction');

  TimeBasedCompaction(int time, int? compactionPercentage) {
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
    final bc = atLogType.entriesCount();
    _logger.finer(
        'Number of entries in $atLogType before time compaction - ${bc}');

    _logger.finer(
        'performing time compaction for $atLogType: Number of expired/duplicate keys: ${expiredKeys.length}');
    // Delete expired keys
    await atLogType.delete(expiredKeys);
    final ac = atLogType.entriesCount();
    _logger.finer(
        'Number of entries in $atLogType after time compaction - ${ac}');
  }
}
