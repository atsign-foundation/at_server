/// Keystore represents a data store like a database which can store mapping between keys and values.
abstract class LogKeyStore<K, V> {
  /// Retrieves the value mapped to [key], or `null` if no mapping
  /// exists.
  Future<V?> get(K key);

  /// Appends [value] to the log. Returns the auto-generated key
  /// assigned to the new entry by the backend.
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<int> add(V value);

  /// Updates the entry at [key] with [value].
  Future<void> update(K key, V value);

  /// Removes the entry at [key] if present.
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<void> remove(K key);

  /// Removes the list of keys from storage.
  Future<void> removeAll(List<K> deleteKeysList);

  /// Returns the total number of keys in storage.
  /// @return int Returns the total number of keys.
  int entriesCount();

  /// Returns the first 'N' keys of the log instance, in
  /// backend-natural order.
  List<int> getFirstNEntries(int N);

  /// Returns the keys whose entries expired more than
  /// [expiryInDays] days ago.
  Future<List<K>> getExpired(int expiryInDays);

  /// Returns the size of the storage
  /// @return int Returns the storage size in integer type.
  int getSize();
}
