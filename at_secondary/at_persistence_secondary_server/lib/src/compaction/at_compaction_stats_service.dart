///base class for compaction statistics
abstract class AtCompactionStatsService {

  Future<void> handleStats(AtCompactionStats);
}
