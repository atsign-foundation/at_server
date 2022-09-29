///base class for compaction statistics
abstract class AtCompactionStatsService {
  ///write statistics received from [AtCompaction]
  Future<void> handleStats(atCompactionStats);
}
