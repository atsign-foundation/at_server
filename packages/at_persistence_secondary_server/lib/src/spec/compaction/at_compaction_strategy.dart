import 'package:at_persistence_secondary_server/src/spec/spec.dart';

///The base class for Log.
abstract class AtLogType<K, V> implements AtCompaction<K, V> {
  /// Returns the total number of keys in storage.
  /// @return int Returns the total number of keys.
  int entriesCount();

  /// Returns the size of the storage
  /// @return int Returns the storage size in integer type.
  int getSize();
}
