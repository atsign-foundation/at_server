import 'package:at_persistence_spec/at_persistence_spec.dart';

abstract class SecondaryKeyStore<K, V, T>
    implements WritableKeystore<K, V>, SynchronizableKeyStore<K, V, T> {
  /// Retrieves all keys have that expired.
  /// @return - List of keys that have expired
  Future<List<K>> getExpiredKeys();

  /// Removes all expired keys from keystore
  Future<bool> deleteExpiredKeys();

  ///Returns the list of keys, optionally keys can be searched on regular expression
  ///@param - String : This is an optional parameter that accepts the regular expression
  /// and returns keys that finds the match
  /// @return - List<K> : Returns list of keys
  Future<List<K>> getKeys({String regex});

  ///Returns the list of values for all the keys
  /// returns all the values
  /// @return - List<V> : Returns list of values
  Future<List<V>> getValues();
}
