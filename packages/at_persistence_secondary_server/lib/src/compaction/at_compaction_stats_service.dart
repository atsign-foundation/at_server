import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

///base class for compaction statistics
abstract class AtCompactionStatsService {
  ///write statistics received from [AtCompaction]
  Future<void> handleStats(AtCompactionStats atCompactionStats);
}
