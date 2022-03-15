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

  ///Compaction triggered when [AtLogType] size meets compaction criteria
  ///Returns [AtCompactionStats] object with statistics calculated from pre and post compaction data
  @override
  Future<AtCompactionStats?> performCompaction(AtLogType atLogType) async {
    DateTime compactionStartTime = DateTime.now().toUtc();
    var isRequired = _isCompactionRequired(atLogType);
    if (isRequired) {
      atCompactionStats = AtCompactionStats();
      var totalKeys = atLogType.entriesCount();
      if (totalKeys > 0) {
        //calculating number of keys to be deleted based on compactionPercentage parameter
        //'N' is the number of keys to be deleted
        var N = (totalKeys * (compactionPercentage! / 100)).toInt();
        var keysToDelete = await atLogType.getFirstNEntries(N);
        //collection of AtLogType statistics before compaction
        atCompactionStats.preCompactionEntriesCount = atLogType.entriesCount();
        atCompactionStats.deletedKeysCount = keysToDelete.length;
        atCompactionStats.compactionType = CompactionType.sizeBasedCompaction;
        if (keysToDelete.isNotEmpty) {
          await atLogType.delete(keysToDelete);
          //collection of statistics post compaction
          atCompactionStats.lastCompactionRun = DateTime.now().toUtc();
          atCompactionStats.postCompactionEntriesCount = atLogType.entriesCount();
          //calculation of compaction duration by comparing present time to compaction start time
          atCompactionStats.compactionDuration = atCompactionStats
              .lastCompactionRun
              ?.difference(compactionStartTime);
          return atCompactionStats;
        } else {
          _logger.finer(
              'No keys to delete. skipping size compaction for $atLogType');
        }
      }
    }
    return null;
  }

  ///checks whether sizeBasedCompaction is required
  bool _isCompactionRequired(AtLogType atLogType) {
    var logStorageSize = 0;
    logStorageSize = atLogType.getSize();
    if (logStorageSize >= sizeInKB) {
      return true;
    }
    return false;
  }
}
