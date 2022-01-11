import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class TimeBasedCompaction implements AtCompactionStrategy {
  late int timeInDays;
  int? compactionPercentage;

  final _logger = AtSignLogger('TimeBasedCompaction');

  TimeBasedCompaction(int time, this.compactionPercentage) {
    timeInDays = time;
  }

  @override
  Future<void> performCompaction(AtLogType atLogType) async {
    var expiredKeys = await atLogType.getExpired(timeInDays);
    // If expired keys is empty, log compaction is not performed.
    if (expiredKeys.isEmpty) {
      _logger.finer('No expired keys. skipping time compaction for $atLogType');
      return;
    }
    _logger.finer(
        'Number of entries in $atLogType before time compaction - ${atLogType.entriesCount()}');
    _logger.finer(
        'performing time compaction for $atLogType: Number of expired/duplicate keys: ${expiredKeys.length}');
    // Delete expired keys
    await atLogType.delete(expiredKeys);
    _logger.finer(
        'Number of entries in $atLogType after time compaction - ${atLogType.entriesCount()}');
  }
}
