/// Keystore represents a data store like a database which can store mapping between keys and values.
// ignore_for_file: non_constant_identifier_names, constant_identifier_names

abstract class Keystore<K, V> {
  /// Retrieves a Future value for the key passed from the key store.
  ///
  /// @param key Key associated with a value.
  /// @return Returns the value to which the specified key is mapped, or null if this map contains no mapping for the key or if key is not null.
  Future<V>? get(K key);
}

/// WritableKeystore represents a data store like a database that allows CRUD operations on the values belonging to the keys
abstract class WritableKeystore<K, V> implements Keystore<K, V> {
  /// Subclasses should put any necessary post-construction async initialization
  /// in this method
  Future<void> initialize() async {}

  /// Associates the specified value with the specified key.
  /// If the key store previously contained a mapping for the key, the old value is replaced by the specified value.
  ///
  /// @param key - Key associated with a value.
  /// @param value - Value to be associated with the specified key.
  /// @param time_to_live - Duration in milliseconds after which the key should expire automatically.
  /// @param time_to_born - Duration in milliseconds after which the key will become active.
  /// @returns sequence number from commit log if put is success. null otherwise
  /// Throws a [DataStoreException] if the the operation fails due to some issue with the data store.
  Future<dynamic> put(K key, V value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum,
      String? encoding,
      String? encKeyName,
      String? encAlgo,
      String? ivNonce,
      String? skeEncKeyName,
      String? skeEncAlgo,
      bool skipCommit = false});

  /// If the specified key is not already associated with a value (or is mapped to null) associates it with the given value and returns null, else returns the current value.
  ///
  /// @param key - Key with which the specified value is to be associated
  /// @param value - Value to be associated with the specified key
  /// @param time_to_live - Duration in milliseconds after which the key should expire automatically.
  /// @param time_to_born - Duration in milliseconds after which the key will become active.
  /// @return - sequence number from commit log if put is success. null otherwise
  /// Throws a [DataStoreException] if the the operation fails due to some issue with the data store.
  Future<dynamic> create(K key, V value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum,
      String? encoding,
      String? encKeyName,
      String? encAlgo,
      String? ivNonce,
      String? skeEncKeyName,
      String? skeEncAlgo});

  /// Removes the mapping for a key from this key store if it is present
  ///
  /// @param key - Key associated with a value.
  /// @return - sequence number from commit log if remove is success. null otherwise
  /// Throws a [DataStoreException] if the operation fails due to some issue with the data store.
  Future<dynamic> remove(K key, {bool skipCommit = false});
}

abstract class SynchronizableKeyStore<K, V, T> {
  Future<dynamic> putMeta(K key, T metadata);

  Future<dynamic> putAll(K key, V value, T metadata);

  Future<T> getMeta(K key);
}

/// Enumeration indicating the store type.
enum StoreType { ROOT, SECONDARY }
