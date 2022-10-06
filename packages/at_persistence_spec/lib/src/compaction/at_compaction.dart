import 'package:at_persistence_spec/at_persistence_spec.dart';

/// Abstract class for [SecondaryKeyStore] and [AtLogType] that requires compaction to be performed.
abstract class AtCompaction {
  /// Set the configuration required for running compaction.
  void setCompactionConfig(AtCompactionConfig atCompactionConfig);

  /// Returns the keys to delete from the [SecondaryKeyStore] or [AtLogType] when compaction job is run
  Future<List> getKeysToDeleteOnCompaction();

  /// Deletes a passed [key] from the [SecondaryKeyStore] or [AtLogType]
  Future<void> deleteKeyForCompaction(String key);
}

class AtCompactionConfig {
  // Percentage of logs to compact
  int? compactionPercentage;
  // Frequency interval in which the logs are compacted
  int? compactionFrequencyMins;
}
