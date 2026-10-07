part of '../command.dart';

/// Positional form of `update`:
/// `update[:nc]<metadataFragment>[:(public|@<forAtSign>)]:<atKey>[@<atSign>] <value>`
///
/// Source: `VerbSyntax.update` (at_commons `syntax.dart:62-73`). The
/// `update[:nc]:json:<json>` form is [UpdateJsonCommand].
final class UpdateCommand extends Command {
  /// `:nc` — skip writing a commit-log entry.
  final bool noCommit;

  /// Metadata tags, which precede the scope and atKey in this verb.
  final MetadataFragment metadata;

  final KeyScope? scope;

  /// The bare atKey, or the reserved literal `privatekey:at_pkam_publickey`.
  final String atKey;

  /// Owning atSign; optional for this verb.
  final String? atSign;

  /// Everything after the single space following the key, unescaped.
  final String value;

  const UpdateCommand({
    required this.atKey,
    required this.value,
    this.atSign,
    this.scope,
    this.metadata = const MetadataFragment(),
    this.noCommit = false,
  });

  @override
  Map<String, Object?> get _fields => {
        'noCommit': noCommit,
        'metadata': metadata,
        'scope': scope,
        'atKey': atKey,
        'atSign': atSign,
        'value': value,
      };
}

/// JSON form of `update`: `update[:nc]:json:<json>`.
///
/// Source: `VerbSyntax.update`'s `json` alternative.
final class UpdateJsonCommand extends Command {
  /// `:nc` — skip writing a commit-log entry.
  final bool noCommit;

  /// Raw JSON payload.
  final String json;

  const UpdateJsonCommand({required this.json, this.noCommit = false});

  @override
  Map<String, Object?> get _fields => {'noCommit': noCommit, 'json': json};
}
