part of '../command.dart';

/// `delete[:dAt:<ISO8601>][:nc][:force][:priority:<low|medium|high>][:cached][:(public|@<forAtSign>)]:<atKey>[@<atSign>]`
///
/// Source: `VerbSyntax.delete` (at_commons `syntax.dart:83-92`).
final class DeleteCommand extends Command {
  /// Caller-asserted deletion time (`:dAt:`).
  final DateTime? deletedAt;

  /// `:nc` — skip writing a commit-log entry.
  final bool noCommit;

  /// `:force` — required to delete an `immutable:true` key.
  final bool force;

  final Priority? priority;

  /// `:cached`. Not a named group in `VerbSyntax.delete`, so the legacy
  /// `processMatches` map cannot observe it.
  final bool cached;

  final KeyScope? scope;

  /// The bare atKey, or the reserved literal `privatekey:at_secret`.
  final String atKey;

  /// Owning atSign; optional for this verb.
  final String? atSign;

  const DeleteCommand({
    required this.atKey,
    this.atSign,
    this.scope,
    this.deletedAt,
    this.noCommit = false,
    this.force = false,
    this.priority,
    this.cached = false,
  });

  @override
  Map<String, Object?> get _fields => {
        'deletedAt': deletedAt,
        'noCommit': noCommit,
        'force': force,
        'priority': priority,
        'cached': cached,
        'scope': scope,
        'atKey': atKey,
        'atSign': atSign,
      };
}
