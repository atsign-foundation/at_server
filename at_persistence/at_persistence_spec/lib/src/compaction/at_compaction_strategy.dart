import 'package:at_persistence_spec/at_persistence_spec.dart';

///The base class for Log.
abstract class AtLogType {
  /// Returns the total number of keys in storage.
  /// @return int Returns the total number of keys.
  int entriesCount();

  /// Returns the first 'N' keys of the log instance.
  /// @param N : Fetches first 'N' entries
  /// @return List : Returns the list of keys.
  Future<List> getFirstNEntries(int N);

  /// Removes the keys from storage.
  /// @param expiredKeys delete the expiredKeys from the storage
  Future<void> delete(dynamic expiredKeys);

  ///Returns the list of expired keys
  ///@param expiryInDays
  ///@return List<dynamic>
  Future<List<dynamic>> getExpired(int expiryInDays);

  /// Returns the size of the storage
  /// @return int Returns the storage size in integer type.
  int getSize();
}

/// The abstract class for Compaction Job
abstract class AtCompactionStrategy {
  /// Performs the compaction on the specified log type.
  /// @param atLogType The log type to perform the compaction job.
  Future<AtCompactionStats> performCompaction(AtLogType atLogType);
}
