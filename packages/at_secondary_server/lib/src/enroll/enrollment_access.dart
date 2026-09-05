/// The access level an enrollment holds over a namespace, and the two
/// questions the server ever asks of one.
abstract final class EnrollmentAccess {
  /// Read-only over a namespace.
  static const String read = 'r';

  /// Read and write over a namespace.
  static const String readWrite = 'rw';

  /// The only two spellings the server will store.
  ///
  /// Raw literals rather than the constants above: a wire vocabulary every
  /// atServer implementation spells out, so an intended change edits the pin.
  static const Set<String> canonicalSpellings = {'r', 'rw'};

  /// Returns [access] when it is a spelling the server acts on, else null.
  static String? canonicalise(String? access) =>
      (access != null && canonicalSpellings.contains(access)) ? access : null;

  /// Whether [access] confers read over the namespace it is attached to.
  ///
  /// Null and empty confer nothing.
  static bool allowsRead(String? access) => _has(access, 'r');

  /// Whether [access] confers write over the namespace it is attached to.
  static bool allowsWrite(String? access) => _has(access, 'w');

  static bool _has(String? access, String letter) =>
      access != null && access.contains(letter);
}
