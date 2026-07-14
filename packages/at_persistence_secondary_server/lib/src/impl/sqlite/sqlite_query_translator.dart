import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Translates the backend-agnostic [KeyPattern] / [Predicate] query types
/// into SQLite. [matchesKeyPattern] mirrors the Hive keystore's
/// `_matchesPattern` exactly (atKey-structure filtering); [predicateToSql]
/// lowers a value-field [Predicate] AST to a `json_extract` WHERE clause.
class SqliteQueryTranslator {
  SqliteQueryTranslator._();

  /// True if [keyString] matches [pattern]. Same semantics as the Hive
  /// keystore: parse the atKey and compare sharedBy / sharedWith
  /// (case-insensitive, `@`-tolerant) / namespace / idPrefix. A malformed
  /// key matches nothing.
  static bool matchesKeyPattern(String keyString, KeyPattern pattern) {
    if (pattern.isUnrestricted) return true;
    final AtKey atKey;
    try {
      atKey = AtKey.fromString(keyString);
    } on Exception {
      return false;
    }
    if (pattern.sharedBy != null &&
        !_atSignEquals(atKey.sharedBy, pattern.sharedBy!)) {
      return false;
    }
    if (pattern.sharedWith != null &&
        !_atSignEquals(atKey.sharedWith, pattern.sharedWith!)) {
      return false;
    }
    if (pattern.namespace != null && atKey.namespace != pattern.namespace) {
      return false;
    }
    if (pattern.idPrefix != null && !atKey.key.startsWith(pattern.idPrefix!)) {
      return false;
    }
    return true;
  }

  static bool _atSignEquals(String? actual, String expected) {
    if (actual == null) return false;
    final a = actual.startsWith('@') ? actual.substring(1) : actual;
    final e = expected.startsWith('@') ? expected.substring(1) : expected;
    return a.toLowerCase() == e.toLowerCase();
  }

  /// Lowers [predicate] to a SQL boolean expression over `json_extract`
  /// of [column]. Returns the SQL fragment and its positional params.
  static ({String sql, List<Object?> params}) predicateToSql(
      Predicate predicate, String column) {
    switch (predicate) {
      case PathEquals p:
        final path = "\$.${p.path.join('.')}";
        if (p.expected == null) {
          return (sql: "json_extract($column, ?) IS NULL", params: [path]);
        }
        final expected = p.expected;
        final bound = expected is bool ? (expected ? 1 : 0) : expected;
        return (sql: "json_extract($column, ?) = ?", params: [path, bound]);
      case And a:
        if (a.children.isEmpty) return (sql: '1=1', params: []);
        return _combine(a.children, 'AND', column);
      case Or o:
        if (o.children.isEmpty) return (sql: '1=0', params: []);
        return _combine(o.children, 'OR', column);
    }
  }

  static ({String sql, List<Object?> params}) _combine(
      List<Predicate> children, String op, String column) {
    final parts = <String>[];
    final params = <Object?>[];
    for (final child in children) {
      final t = predicateToSql(child, column);
      parts.add('(${t.sql})');
      params.addAll(t.params);
    }
    return (sql: parts.join(' $op '), params: params);
  }
}
