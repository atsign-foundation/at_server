import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_persistence_spec/src/compaction/at_compaction.dart';

///The base class for Log.
abstract class AtLogType extends AtCompaction {
  /// Returns the total number of keys in storage.
  /// @return int Returns the total number of keys.
  int entriesCount();

  /// Returns the size of the storage
  /// @return int Returns the storage size in integer type.
  int getSize();
}

/// The abstract class for Compaction Job
abstract class AtCompactionStrategy {
  /// Performs the compaction on the specified log type.
  /// @param atLogType The log type to perform the compaction job.
  @Deprecated('use CompactionService')
  Future<AtCompactionStats?> performCompaction(AtLogType atLogType);
}
