/// Structured filter for key-store scans. Supersedes the
/// regex-string-only [`AtKeyValueStore.getKeys(regex: ...)`]
/// API for callers that want backend-portable key enumeration.
///
/// All fields are independently optional. A `null` field means
/// "any" along that dimension. Multiple non-null fields are
/// AND-combined: a key matches the pattern only if it satisfies
/// every non-null field.
///
/// Field semantics map onto the standard atKey shape
/// `<sharedWith>:<id>.<namespace>@<sharedBy>` (with optional
/// `public:` / `cached:` / `private:` / `local:` prefixes):
///
/// - [sharedBy]:    exact match on the owner suffix after `@`.
/// - [sharedWith]:  exact match on the recipient prefix before
///                  the first `:`. Public / self / private keys
///                  have no sharedWith and only match when
///                  [sharedWith] is `null`.
/// - [namespace]:   exact match on the dot-suffix after the id.
/// - [idPrefix]:    leading-substring match on the id segment.
///
/// Backend implementations are free to optimise by maintaining
/// secondary indexes keyed by these fields. The Hive impl in
/// `at_persistence_secondary_server` currently iterates and
/// filters (O(box-size)); SQL backends translate the pattern
/// into composite-index `WHERE` clauses (O(matching)).
class KeyPattern {
  /// Owner atSign — e.g. `'@alice'`. Matches keys ending in
  /// `@alice` (case-insensitive).
  final String? sharedBy;

  /// Recipient atSign — e.g. `'@bob'`. Matches keys whose
  /// sharedWith prefix is `@bob:`. For public / self / private
  /// keys (no sharedWith), pass `null` to match them; pass a
  /// non-null value to exclude them.
  final String? sharedWith;

  /// Namespace dot-suffix — e.g. `'wavi'`. Matches keys whose
  /// id segment ends in `.wavi`.
  final String? namespace;

  /// Prefix on the id segment — e.g. `'phone'` matches the keys
  /// `phone`, `phone_v2`, `phoneNumber`, etc.
  final String? idPrefix;

  const KeyPattern({
    this.sharedBy,
    this.sharedWith,
    this.namespace,
    this.idPrefix,
  });

  /// `true` iff every non-null field on this pattern is also
  /// `null` — i.e. matches every key.
  bool get isUnrestricted =>
      sharedBy == null &&
      sharedWith == null &&
      namespace == null &&
      idPrefix == null;

  @override
  String toString() => 'KeyPattern('
      'sharedBy: $sharedBy, '
      'sharedWith: $sharedWith, '
      'namespace: $namespace, '
      'idPrefix: $idPrefix)';
}
