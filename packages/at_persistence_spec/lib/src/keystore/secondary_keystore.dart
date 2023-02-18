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
  List<K> getKeys({String? regex});

  /// Checks whether the keystore contains the key. Returns a true if key is present, else false.
  bool isKeyExists(String key);

  /// A SecondaryKeyStore has an associated commit log
  AtLogType? get commitLog;

  /// A SecondaryKeyStore has an associated commit log
  set commitLog(AtLogType? log);
}
