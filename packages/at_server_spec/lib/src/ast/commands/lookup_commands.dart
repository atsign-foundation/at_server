part of '../command.dart';

/// `lookup[:bypassCache:<true|false>]:[(meta|all):]<atKey>@<atSign>`
///
/// Source: `VerbSyntax.lookup` (at_commons `syntax.dart:19-20`). atKey class
/// `(?:[^:]).+` — the loosest of the three lookup verbs.
final class LookupCommand extends Command {
  final bool? bypassCache;
  final LookupOperation? operation;
  final String atKey;
  final String atSign;

  const LookupCommand({
    required this.atKey,
    required this.atSign,
    this.bypassCache,
    this.operation,
  });

  @override
  Map<String, Object?> get _fields => {
        'bypassCache': bypassCache,
        'operation': operation,
        'atKey': atKey,
        'atSign': atSign,
      };
}

/// `plookup[:bypassCache:<true|false>]:[(meta|all):]<atKey>@<atSign>`
///
/// Source: `VerbSyntax.plookup` (at_commons `syntax.dart:17-18`). atKey
/// class `[^@\s]+` — colons allowed.
final class PLookupCommand extends Command {
  final bool? bypassCache;
  final LookupOperation? operation;
  final String atKey;
  final String atSign;

  const PLookupCommand({
    required this.atKey,
    required this.atSign,
    this.bypassCache,
    this.operation,
  });

  @override
  Map<String, Object?> get _fields => {
        'bypassCache': bypassCache,
        'operation': operation,
        'atKey': atKey,
        'atSign': atSign,
      };
}

/// `llookup[:(meta|all)][:cached][:(public|@<forAtSign>)]:<atKey>@<atSign>`
///
/// Source: `VerbSyntax.llookup` (at_commons `syntax.dart:11-16`).
final class LLookupCommand extends Command {
  final LookupOperation? operation;

  /// `:cached`. Not a named group in `VerbSyntax.llookup`, so the legacy
  /// `processMatches` map cannot observe it.
  final bool cached;

  final KeyScope? scope;
  final String atKey;
  final String atSign;

  const LLookupCommand({
    required this.atKey,
    required this.atSign,
    this.scope,
    this.operation,
    this.cached = false,
  });

  @override
  Map<String, Object?> get _fields => {
        'operation': operation,
        'cached': cached,
        'scope': scope,
        'atKey': atKey,
        'atSign': atSign,
      };
}
