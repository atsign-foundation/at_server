part of '../command.dart';

/// `update:meta[:nc][:(public|@<forAtSign>)]:<atKey>@<atSign><metadataFragment>`
///
/// Source: `VerbSyntax.update_meta` (at_commons `syntax.dart:76-82`).
/// Unlike [UpdateCommand], the metadata fragment comes after the key here.
final class UpdateMetaCommand extends Command {
  /// `:nc` — skip writing a commit-log entry.
  final bool noCommit;

  final KeyScope? scope;

  /// The bare atKey.
  final String atKey;

  /// Owning atSign; required for this verb.
  final String atSign;

  /// Metadata tags, which follow the atSign in this verb.
  final MetadataFragment metadata;

  const UpdateMetaCommand({
    required this.atKey,
    required this.atSign,
    this.scope,
    this.metadata = const MetadataFragment(),
    this.noCommit = false,
  });

  @override
  Map<String, Object?> get _fields => {
        'noCommit': noCommit,
        'scope': scope,
        'atKey': atKey,
        'atSign': atSign,
        'metadata': metadata,
      };
}
