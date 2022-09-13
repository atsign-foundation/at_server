///base class for compaction statistics
abstract class AtCompactionStatsService {
  ///write statistics received from [AtTimeBasedCompaction]/[AtSizeBasedCompaction] into keystore
  // ignore: non_constant_identifier_names
  Future<void> handleStats(AtCompactionStats);
}
