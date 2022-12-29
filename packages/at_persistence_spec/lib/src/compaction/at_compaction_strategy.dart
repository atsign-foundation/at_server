import 'package:at_persistence_spec/at_persistence_spec.dart';

///The base class for Log.
abstract class AtLogType<K, V> implements AtCompaction<K, V> {
  /// Returns the total number of keys in storage.
  /// @return int Returns the total number of keys.
  int entriesCount();

  /// Returns the size of the storage
  /// @return int Returns the storage size in integer type.
  int getSize();
}

/// The abstract class for Compaction Job
@Deprecated('use CompactionService')
abstract class AtCompactionStrategy {
  /// Performs the compaction on the specified log type.
  /// @param atLogType The log type to perform the compaction job.
  @Deprecated('use CompactionService')
  Future<AtCompactionStats?> performCompaction(AtLogType atLogType);
}
