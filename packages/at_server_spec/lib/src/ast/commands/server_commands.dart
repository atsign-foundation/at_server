part of '../command.dart';

/// `config:block:(add|remove):@<atSign>[ @<atSign>...]` or
/// `config:block:show`.
///
/// Source: `VerbSyntax.config`'s first alternative (at_commons
/// `syntax.dart:28`). The other alternative is [ConfigSettingCommand].
final class ConfigBlockCommand extends Command {
  final BlockOperation operation;

  /// Space-separated on the wire, each with `@`; stored without it. Empty
  /// for `show`.
  final List<String> atSigns;

  ConfigBlockCommand({required this.operation, List<String> atSigns = const []})
      : atSigns = List.unmodifiable(atSigns);

  @override
  Map<String, Object?> get _fields =>
      {'operation': operation, 'atSigns': atSigns};
}

/// `config:(set|reset|print):<configNew>`
///
/// Source: `VerbSyntax.config`'s second alternative (at_commons
/// `syntax.dart:28`). [configNew] is undifferentiated free text
/// (`key=value` for `set`, `key` otherwise); the grammar doesn't split it.
final class ConfigSettingCommand extends Command {
  final ConfigSettingOperation operation;
  final String configNew;

  const ConfigSettingCommand(
      {required this.operation, required this.configNew});

  @override
  Map<String, Object?> get _fields =>
      {'operation': operation, 'configNew': configNew};
}

/// `stats[:<id>[,<id>...]][:<regex>]`
///
/// Source: `VerbSyntax.stats` (at_commons `syntax.dart:29-30`). The regex
/// is only accepted after ids ending in `3` or `15`.
final class StatsCommand extends Command {
  /// Metric ids in wire order; empty means all metrics.
  final List<int> statIds;
  final String? regex;

  StatsCommand({List<int> statIds = const [], this.regex})
      : statIds = List.unmodifiable(statIds);

  @override
  Map<String, Object?> get _fields => {'statIds': statIds, 'regex': regex};
}

/// `info[:(brief|mtls|mtlsbrief)]`
///
/// Source: `VerbSyntax.info` (at_commons `syntax.dart:154`).
final class InfoCommand extends Command {
  final InfoMode? mode;

  const InfoCommand({this.mode});

  @override
  Map<String, Object?> get _fields => {'mode': mode};
}

/// `noop:<delayMillis>`
///
/// Source: `VerbSyntax.noOp` (at_commons `syntax.dart:155`).
final class NoopCommand extends Command {
  final int delayMillis;

  const NoopCommand({required this.delayMillis});

  @override
  Map<String, Object?> get _fields => {'delayMillis': delayMillis};
}

/// `batch:<json>`
///
/// Source: `VerbSyntax.batch` (at_commons `syntax.dart:153`).
final class BatchCommand extends Command {
  /// Raw JSON array of `{"id":<n>,"command":"<verb>"}`.
  final String json;

  const BatchCommand({required this.json});

  @override
  Map<String, Object?> get _fields => {'json': json};
}
