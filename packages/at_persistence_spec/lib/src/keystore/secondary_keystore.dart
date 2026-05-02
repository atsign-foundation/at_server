import 'package:at_persistence_spec/at_persistence_spec.dart';

abstract interface class SecondaryKeyStore<K, V, T>
    implements WritableKeystore<K, V>, SynchronizableKeyStore<K, V, T> {
  /// Retrieves all keys have that expired.
  /// @return - List of keys that have expired
  Future<List<K>> getExpiredKeys();

  /// Removes all expired keys from keystore
  Future<bool> deleteExpiredKeys();

  ///Returns the list of keys, optionally keys can be searched on regular expression
  ///@param - String : This is an optional parameter that accepts the regular expression
  /// and returns keys that finds the match
  /// @return - `List<K>` : Returns list of keys
  List<K> getKeys({String? regex});

  /// Checks whether the keystore contains the key. Returns a true if key is present, else false.
  ///
  /// Synchronous flavour intended for in-process Hive-backed consumers
  /// where blocking on I/O is fine. Async-only backends (e.g. SQLite,
  /// Postgres) should use [exists] instead — the async signature is
  /// the canonical forward-compat shape.
  bool isKeyExists(String key);

  /// Returns `true` if the keystore currently contains [key], else
  /// `false`. The async flavour of [isKeyExists] — backend-agnostic
  /// consumers (e.g. at_client) should prefer this so the same call
  /// site works against Hive, SQLite, and any future backend.
  ///
  /// Should be O(1) on every backend that ships with this package
  /// (Hive uses `Box.containsKey`; SQL backends use an indexed
  /// `SELECT 1 ... LIMIT 1`). Consumers may rely on it being
  /// significantly cheaper than `getKeys(regex: '^exact$')` or
  /// `get(key) != null`.
  Future<bool> exists(String key);

  /// A SecondaryKeyStore has an associated commit log
  AtLogType? get commitLog => null;

  /// A SecondaryKeyStore has an associated commit log
  set commitLog(AtLogType? log) {}
}
