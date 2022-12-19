import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// The [AtCompactionStatsService] collects compaction metrics and writes them to [SecondaryKeyStore]
abstract class AtCompactionStatsService {
  ///write statistics received from [AtCompaction]
  Future<void> handleStats(AtCompactionStats atCompactionStats);
}
