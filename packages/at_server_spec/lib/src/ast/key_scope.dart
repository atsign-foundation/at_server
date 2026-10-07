/// The `public` / `@<forAtSign>` scope segment that precedes an atKey in
/// several verbs (e.g. `delete`, `llookup`, `update`, `notify`).
///
/// Verbs where the segment is optional model its absence as a `null`
/// [KeyScope]; `notify`, where it is required, takes a non-null one.
sealed class KeyScope {
  const KeyScope();
}

/// The `:public` scope.
final class PublicScope extends KeyScope {
  const PublicScope();

  @override
  bool operator ==(Object other) => other is PublicScope;

  @override
  int get hashCode => (PublicScope).hashCode;

  @override
  String toString() => 'PublicScope()';
}

/// The `:@<forAtSign>` scope.
final class SharedWithScope extends KeyScope {
  /// The recipient atSign, without the leading `@` (as captured by the
  /// legacy `forAtSign` regex group).
  final String forAtSign;

  const SharedWithScope(this.forAtSign);

  @override
  bool operator ==(Object other) =>
      other is SharedWithScope && other.forAtSign == forAtSign;

  @override
  int get hashCode => forAtSign.hashCode;

  @override
  String toString() => 'SharedWithScope($forAtSign)';
}
