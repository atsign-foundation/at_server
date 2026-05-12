/// A single mutation observed on a [AtKeyValueStore]. The base
/// type exposes [key]; subclasses describe what happened.
///
/// `KeyStoreChange` is a sealed hierarchy: every concrete subtype
/// is declared here, so `switch` over a stream event is exhaustive
/// without a default branch.
sealed class KeyStoreChange {
  /// The key that was mutated, in the keystore's canonical form
  /// (lowercased; for atKey-shaped keys, the
  /// `<sharedWith>:<id>.<namespace>@<sharedBy>` shape).
  final String key;

  const KeyStoreChange(this.key);
}

/// Emitted when a key was inserted into the keystore for the first
/// time (i.e. the previous state had no value at this key).
final class KeyAdded extends KeyStoreChange {
  const KeyAdded(super.key);

  @override
  String toString() => 'KeyAdded($key)';
}

/// Emitted when an existing key's value (or metadata) was replaced.
final class KeyUpdated extends KeyStoreChange {
  const KeyUpdated(super.key);

  @override
  String toString() => 'KeyUpdated($key)';
}

/// Emitted when a key was removed from the keystore. Carries only
/// the key name; the prior value is not preserved.
final class KeyRemoved extends KeyStoreChange {
  const KeyRemoved(super.key);

  @override
  String toString() => 'KeyRemoved($key)';
}
