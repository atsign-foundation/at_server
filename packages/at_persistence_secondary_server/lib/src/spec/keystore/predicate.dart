/// A filter predicate over the value's structured fields. Used by
/// [`AtKeyValueStore.queryByPath`] to push value-field filtering
/// down to the backend.
///
/// Sealed: every concrete subtype lives in this file. Backends
/// translate the AST into their native query language (SQL JSON
/// extraction on SQLite/Postgres; a programmatic walker on Hive,
/// when `supportsPathQueries` is `true` — Hive's default impl is
/// `false` so the AST is never executed there).
///
/// The type is intentionally minimal in the initial cut; a future
/// SQL-backed implementation will drive whatever extensions (range
/// queries, regex, IN-set) the real query needs.
sealed class Predicate {
  const Predicate();
}

/// Matches when the value at [path] equals [expected]. The path
/// is a dot-style accessor into the stored JSON-shaped value
/// (e.g. `['obj', 'amount']` walks `value.obj.amount`).
final class PathEquals extends Predicate {
  /// Field-access path into the value's JSON shape. Must be
  /// non-empty.
  final List<String> path;

  /// The expected value. May be `null`, in which case the
  /// predicate matches when the field IS null on the value.
  final Object? expected;

  const PathEquals(this.path, this.expected);

  @override
  String toString() => 'PathEquals(${path.join('.')} = $expected)';
}

/// Logical AND of [children]. An empty children list matches every
/// value (vacuous truth).
final class And extends Predicate {
  final List<Predicate> children;

  const And(this.children);

  @override
  String toString() => 'And(${children.join(', ')})';
}

/// Logical OR of [children]. An empty children list matches no
/// values (vacuous falsity).
final class Or extends Predicate {
  final List<Predicate> children;

  const Or(this.children);

  @override
  String toString() => 'Or(${children.join(', ')})';
}
