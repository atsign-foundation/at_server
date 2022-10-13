///base class for compaction statistics
abstract class AtCompactionStatsService {
  ///write statistics received from [AtTimeBasedCompaction]/[AtSizeBasedCompaction] into keystore
  Future<void> handleStats(atCompactionStats);
}
