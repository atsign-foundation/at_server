import 'package:at_persistence_spec/at_persistence_spec.dart';

/// AtCompaction deletes keys from the [Keystore] to reduce the size of the KeyStore.
///
/// Gets all the keys that match the criteria set in the [AtCompactionConfig]
/// and removes from the Keystore.
///
/// Abstract class for [SecondaryKeyStore] and [AtLogType] that requires compaction to be performed.
abstract class AtCompaction<K, V> {
  /// Set the configuration required for running compaction.
  void setCompactionConfig(AtCompactionConfig atCompactionConfig);

  /// Returns the keys to delete from the [SecondaryKeyStore] or [AtLogType] when compaction job is run
  Future<List<K>> getKeysToDeleteOnCompaction();

  /// Deletes a passed [key] from the [SecondaryKeyStore] or [AtLogType]
  Future<void> deleteKeyForCompaction(List<K> key);
}

/// The configurations for the AtCompaction Job.
class AtCompactionConfig {
  /// Indicates the percentage of the [KeyStore] to shrink.
  int? compactionPercentage;

  /// Indicates the frequency of time interval in minutes at which the compaction job should run.
  int? compactionFrequencyInMins;
}
