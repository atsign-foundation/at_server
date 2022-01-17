import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class SizeBasedCompaction implements AtCompactionStrategy {
  late int sizeInKB;
  int? compactionPercentage;
  late AtCompactionStats atCompactionStats;
  final _logger = AtSignLogger('TimeBasedCompaction');

  SizeBasedCompaction(int size, this.compactionPercentage) {
    sizeInKB = size;
  }

  ///compaction triggered when [AtLogType] size meets compaction criteria
  @override
  Future<AtCompactionStats> performCompaction(AtLogType atLogType) async {
    DateTime compactionStartTime = DateTime.now().toUtc();
    var isRequired = _isCompactionRequired(atLogType);
    if (isRequired) {
      var totalKeys = atLogType.entriesCount();
      if (totalKeys > 0) {
        var N = (totalKeys * (compactionPercentage! / 100)).toInt();
        var keysToDelete = await atLogType.getFirstNEntries(N);
        atCompactionStats = AtCompactionStats();
        atCompactionStats.sizeBeforeCompaction = atLogType.getSize();
        atCompactionStats.deletedKeysCount = keysToDelete.length;
        atCompactionStats.compactionType = CompactionType.SizeBasedCompaction;
        if (keysToDelete.isNotEmpty) {
          await atLogType.delete(keysToDelete);
          atCompactionStats.lastCompactionRun = DateTime.now().toUtc();
          atCompactionStats.sizeAfterCompaction = atLogType.getSize();
          atCompactionStats.compactionDuration = atCompactionStats
              .lastCompactionRun
              .difference(compactionStartTime);
        } else {
          _logger.finer(
              'No keys to delete. skipping size compaction for $atLogType');
        }
      }
    }

    return atCompactionStats;
  }

  bool _isCompactionRequired(AtLogType atLogType) {
    var logStorageSize = 0;
    logStorageSize = atLogType.getSize();
    if (logStorageSize >= sizeInKB) {
      return true;
    }
    return false;
  }
}
