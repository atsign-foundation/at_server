import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class SizeBasedCompaction implements AtCompactionStrategy {
  late int sizeInKB;
  int? compactionPercentage;
  final _logger = AtSignLogger('TimeBasedCompaction');

  SizeBasedCompaction(int size, this.compactionPercentage) {
    sizeInKB = size;
  }

  @override
  Future<void> performCompaction(AtLogType atLogType) async {
    var isRequired = _isCompactionRequired(atLogType);
    if (isRequired) {
      var totalKeys = atLogType.entriesCount();
      if (totalKeys > 0) {
        var N = (totalKeys * (compactionPercentage! / 100)).toInt();
        var keysToDelete = await atLogType.getFirstNEntries(N);
        if (keysToDelete.isNotEmpty) {
          _logger.finer(
              'Number of entries in $atLogType before size compaction - ${atLogType.entriesCount()}');
          _logger.finer(
              'performing size compaction for $atLogType: Number of expired keys: ${keysToDelete.length}');
          await atLogType.delete(keysToDelete);
          _logger.finer(
              'Number of entries in $atLogType after size compaction - ${atLogType.entriesCount()}');
        } else {
          _logger.finer(
              'No keys to delete. skipping size compaction for $atLogType');
        }
      }
    }
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
