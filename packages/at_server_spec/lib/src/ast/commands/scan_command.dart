part of '../command.dart';

/// `scan[:cl][:showhidden:<true|false>][:@<forAtSign>][:page:<n>][ <regex>]`
///
/// Source: `VerbSyntax.scan` (at_commons `syntax.dart:21-26`). A bare `scan`
/// is the all-defaults node.
final class ScanCommand extends Command {
  /// `:cl` — scan the commit log instead of the keystore.
  final bool commitLog;

  final bool? showHidden;

  /// The legacy regex captures this with its `@`; stored without it here.
  final String? forAtSign;

  final int? page;

  /// Raw key-filter regex.
  final String? regex;

  const ScanCommand({
    this.commitLog = false,
    this.showHidden,
    this.forAtSign,
    this.page,
    this.regex,
  });

  @override
  Map<String, Object?> get _fields => {
        'commitLog': commitLog,
        'showHidden': showHidden,
        'forAtSign': forAtSign,
        'page': page,
        'regex': regex,
      };
}
