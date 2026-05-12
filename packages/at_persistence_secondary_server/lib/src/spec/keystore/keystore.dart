/// Keystore represents a data store like a database which can store mapping between keys and values.
abstract interface class Keystore<K, V> {
  /// Retrieves the value mapped to [key], or `null` if no mapping
  /// exists. Implementations may also throw a backend-specific
  /// not-found exception (e.g. `KeyNotFoundException`) instead of
  /// returning `null` — consult the concrete impl.
  Future<V?> get(K key);
}

/// WritableKeystore represents a data store like a database that allows CRUD operations on the values belonging to the keys
abstract interface class WritableKeystore<K, V> implements Keystore<K, V> {
  /// Subclasses should put any necessary post-construction async initialization
  /// in this method
  Future<void> initialize() async {}

  /// Associates [value] with [key]. If a mapping already exists for
  /// [key], the old value is replaced.
  ///
  /// Returns the commit-log sequence number assigned to this write,
  /// or `null` if no sequence number was produced (for example when
  /// [skipCommit] is `true`, or when the backend does not maintain
  /// a commit log).
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<int?> put(K key, V value, {bool skipCommit = false});

  /// If no mapping exists for [key], associates it with [value] and
  /// returns the commit-log sequence number; otherwise behaviour is
  /// implementation-defined (typically throws a key-already-exists
  /// exception).
  ///
  /// Returns the commit-log sequence number assigned to this write,
  /// or `null` if no sequence number was produced.
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<int?> create(K key, V value, {bool skipCommit = false});

  /// Removes the mapping for [key] if present.
  ///
  /// Returns the commit-log sequence number assigned to this
  /// deletion, or `null` if no sequence number was produced (for
  /// example when [skipCommit] is `true`, or the key did not exist).
  ///
  /// Throws a [DataStoreException] if the underlying store fails.
  Future<int?> remove(K key, {bool skipCommit = false});

  List<Future<void> Function(String key, {required bool skipCommit})>
      get preRemoveHooks;
  List<Future<void> Function(String key, {required bool skipCommit})>
      get postRemoveHooks;
}

abstract interface class SynchronizableKeyStore<K, V, T> {
  /// Updates the metadata for [key]. Returns the commit-log
  /// sequence number assigned to this write, or `null` if no
  /// sequence number was produced.
  Future<int?> putMeta(K key, T metadata);

  /// Writes [value] and [metadata] for [key] atomically. Returns the
  /// commit-log sequence number assigned to this write, or `null`
  /// if no sequence number was produced.
  Future<int?> putAll(K key, V value, T metadata);

  Future<T> getMeta(K key);
}

/// Enumeration indicating the store type.
// ignore: constant_identifier_names
enum StoreType { ROOT, SECONDARY }
