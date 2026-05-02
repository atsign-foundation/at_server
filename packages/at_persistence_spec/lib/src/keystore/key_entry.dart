/// A single record yielded by [`SecondaryKeyStore.queryByPath`] —
/// a (key, value, metadata) tuple. Generic-typed against the
/// keystore's K / V / T parameters, so callers see properly-typed
/// fields without needing to cast.
class KeyEntry<K, V, T> {
  /// The keystore key (in canonical form — Hive lowercases atKeys).
  final K key;

  /// The value stored at [key].
  final V data;

  /// The metadata associated with [key], if any.
  final T metadata;

  const KeyEntry(this.key, this.data, this.metadata);

  @override
  String toString() =>
      'KeyEntry(key: $key, data: $data, metadata: $metadata)';
}
