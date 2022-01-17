///base class for compaction statistics
abstract class AtCompactionStatsService {
  ///writes compaction statistics into keystore
  Future<void> handleStats(AtCompactionStats);
}
