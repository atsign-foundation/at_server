/// Handle passed to a `transaction(body)` callback. Within the
/// body, mutations recorded via this handle are buffered in memory;
/// reads via this handle see the buffered state on top of the
/// underlying keystore. At successful body completion the buffered
/// mutations are applied to the keystore (and `changes` events
/// fire). If the body throws, the buffered mutations are dropped
/// and no events fire.
///
/// Hive's atomicity is best-effort: writes are durable per
/// underlying box flush, but a process crash mid-commit can leave
/// the keystore with a subset of the buffered ops applied. A
/// future SQL backend will provide true atomicity via
/// `BEGIN IMMEDIATE` / `COMMIT`.
///
/// Lifetime: the handle is valid only for the duration of the body
/// callback. Calling any method on it after `transaction(...)`
/// returns is undefined behaviour.
abstract class KeyStoreTxn<K, V, T> {
  /// Buffer a write of [value] (with [metadata]) under [key].
  /// Visible to subsequent [get] / [exists] calls on the same
  /// handle; applied to the underlying keystore at commit.
  Future<void> put(K key, V value, T metadata);

  /// Buffer a deletion of [key]. Subsequent [exists] returns
  /// `false`; subsequent [get] returns `null`. The actual delete
  /// happens at commit.
  Future<void> remove(K key);

  /// Returns the value [key] would resolve to within this
  /// transaction's view. Reflects any buffered write (the buffered
  /// value), buffered deletion (`null`), or otherwise the value
  /// already in the underlying keystore.
  Future<V?> get(K key);

  /// Returns `true` if [key] would resolve to a value within this
  /// transaction's view. Reflects buffered writes / deletions on
  /// top of the underlying keystore.
  Future<bool> exists(K key);
}
