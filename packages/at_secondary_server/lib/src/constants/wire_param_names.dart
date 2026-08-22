/// Named-group names from at_commons `VerbSyntax` that have no
/// `AtConstants` entry. Each string must match its regex group name
/// exactly — the name is the only link between the grammar and the
/// handler that reads the parsed param.
class WireParams {
  // Don't instantiate.
  WireParams._();

  /// `:nc` on update / update:meta / update:json / delete.
  static const String noCommit = 'noCommit';

  /// `:dAt:<ISO 8601 UTC>` on delete.
  static const String deletedAt = 'deletedAt';

  /// `:eAt:<ISO 8601 UTC>` in the metadata fragment.
  static const String expiresAt = 'expiresAt';

  /// `:aAt:<ISO 8601 UTC>` in the metadata fragment.
  static const String availableAt = 'availableAt';

  /// `:cl` on scan.
  static const String commitLog = 'commitLog';
}
