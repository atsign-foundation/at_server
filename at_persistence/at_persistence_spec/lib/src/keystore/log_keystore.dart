/// Keystore represents a data store like a database which can store mapping between keys and values.
abstract class LogKeyStore<K, V> {
  /// Retrieves a Future value for the key passed from the key store.
  ///
  /// @param key Key associated with a value.
  /// @return Returns the value to which the specified key is mapped, or null if this map contains no mapping for the key or if key is not null.
  Future<V> get(K key);
  /// Associates the specified value with the specified key.
  /// If the key store previously contained a mapping for the key, the old value is replaced by the specified value.
  ///
  /// @param key - Key associated with a value.
  /// @param value - Value to be associated with the specified key.
  /// @returns sequence number from commit log if put is success. null otherwise
  /// Throws a [DataStoreException] if the the operation fails due to some issue with the data store.
  Future<dynamic> add(V value);

  Future<dynamic> update(K key, V value);
  /// Removes the mapping for a key from this key store if it is present
  ///
  /// @param key - Key associated with a value.
  /// @return - sequence number from commit log if remove is success. null otherwise
  /// Throws an [DataStoreException] if the the operation fails due to some issue with the data store.
  Future<dynamic> remove(K key);

  /// Returns the total number of keys in storage.
  /// @return int Returns the total number of keys.
  int entriesCount();

  /// Returns the first 'N' keys of the log instance.
  /// @param N : Fetches first 'N' entries
  /// @return List : Returns the list of keys.
  List getFirstNEntries(int N);

  /// Removes the keys from storage.
  /// @param expiredKeys delete the expiredKeys from the storage
  void delete(dynamic expiredKeys);

  ///Returns the list of expired keys
  ///@param expiryInDays
  ///@return List<dynamic>
  List<dynamic> getExpired(int expiryInDays);

  /// Returns the size of the storage
  /// @return int Returns the storage size in integer type.
  int getSize();

}
