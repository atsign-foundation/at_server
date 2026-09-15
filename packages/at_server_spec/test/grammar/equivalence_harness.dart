import 'dart:collection';

import 'package:at_server_spec/grammar.dart';
import 'package:test/test.dart';

/// The legacy oracle: reproduces the SERVER's parse semantics exactly —
/// `regex_util.processMatches` over `RegExp(pattern, caseSensitive: false)`,
/// KEEPING null groups (unlike at_commons' own VerbUtil._processMatches which
/// drops them). Returns null when the pattern does not match.
Map<String, String?>? legacyParse(String pattern, String command) {
  final matches = RegExp(pattern, caseSensitive: false).allMatches(command);
  if (matches.isEmpty) return null;
  final map = HashMap<String, String?>();
  for (final m in matches) {
    for (final name in m.groupNames) {
      map.putIfAbsent(name, () => m.namedGroup(name));
    }
  }
  return map;
}

/// Extract the named-group names declared in a regex source string.
Set<String> namedGroupsOf(String pattern) => RegExp(r'\(\?<([A-Za-z_]\w*)>')
    .allMatches(pattern)
    .map((m) => m.group(1)!)
    .toSet();

/// Assert the lexer and the regex agree on [command] — same match/no-match, and
/// identical group maps (keys, null-vs-''-vs-value).
void expectEquivalent(VerbGrammar grammar, String pattern, String command) {
  final legacy = legacyParse(pattern, command);
  final lexed = grammar.parse(command);
  if (legacy == null) {
    expect(lexed, isNull,
        reason: 'regex REJECTS but lexer ACCEPTS: ${_show(command)}\n'
            'lexer => $lexed');
    return;
  }
  expect(lexed, isNotNull,
      reason: 'regex ACCEPTS but lexer REJECTS: ${_show(command)}\n'
          'regex => $legacy');
  expect(lexed, equals(legacy),
      reason: 'group maps differ for ${_show(command)}');
}

String _show(String s) => "'$s'";
