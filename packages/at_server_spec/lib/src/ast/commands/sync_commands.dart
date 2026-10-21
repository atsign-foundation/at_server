part of '../command.dart';

/// `sync:from:<fromCommitSeq>[:limit:<n>][:skipDeletesUntil:<n>][:<regex>]`
///
/// Source: `VerbSyntax.syncFrom` (at_commons `syntax.dart:33-34`).
final class SyncFromCommand extends Command {
  /// A commit sequence number, or `-1`.
  final int fromCommitSeq;
  final int? limit;
  final int? skipDeletesUntil;
  final String? regex;

  const SyncFromCommand({
    required this.fromCommitSeq,
    this.limit,
    this.skipDeletesUntil,
    this.regex,
  });

  @override
  Map<String, Object?> get _fields => {
        'fromCommitSeq': fromCommitSeq,
        'limit': limit,
        'skipDeletesUntil': skipDeletesUntil,
        'regex': regex,
      };
}

/// Legacy `sync:<fromCommitSeq>[:<regex>]`, kept for compatibility.
///
/// Source: `VerbSyntax.sync` (at_commons `syntax.dart:32`, `@Deprecated`).
final class SyncCommand extends Command {
  /// A commit sequence number, or `-1`.
  final int fromCommitSeq;
  final String? regex;

  const SyncCommand({required this.fromCommitSeq, this.regex});

  @override
  Map<String, Object?> get _fields =>
      {'fromCommitSeq': fromCommitSeq, 'regex': regex};
}
