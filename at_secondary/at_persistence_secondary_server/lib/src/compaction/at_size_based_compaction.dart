import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';

class SizeBasedCompaction implements AtCompactionStrategy {
  int sizeInKB;
  int compactionPercentage;

  SizeBasedCompaction(int size, int compactionPercentage) {
    sizeInKB = size;
    this.compactionPercentage = compactionPercentage;
  }

  @override
  Future<void> performCompaction(AtLogType atLogType) async {
    var isRequired = await _isCompactionRequired(atLogType);
    if (isRequired) {
      var totalKeys = await atLogType.entriesCount();
      if (totalKeys > 0) {
        var N = (totalKeys * (compactionPercentage / 100)).toInt();
        var keysToDelete = await atLogType.getFirstNEntries(N);
        await atLogType.remove(keysToDelete);
      }
    }
  }

  Future<bool> _isCompactionRequired(AtLogType atLogType) async {
    var logStorageSize = 0;
    logStorageSize = await atLogType.getSize();
    if (logStorageSize >= sizeInKB) {
      return true;
    }
    return false;
  }
}
