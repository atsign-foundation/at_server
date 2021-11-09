import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';

class SizeBasedCompaction implements AtCompactionStrategy {
  late int sizeInKB;
  int? compactionPercentage;

  SizeBasedCompaction(int size, int? compactionPercentage) {
    sizeInKB = size;
    this.compactionPercentage = compactionPercentage;
  }

  @override
  Future<void> performCompaction(AtLogType atLogType) async {
    var isRequired = _isCompactionRequired(atLogType);
    if (isRequired) {
      var totalKeys = atLogType.entriesCount();
      if (totalKeys > 0) {
        var N = (totalKeys * (compactionPercentage! / 100)).toInt();
        var keysToDelete = await atLogType.getFirstNEntries(N);
        atLogType.delete(keysToDelete);
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
