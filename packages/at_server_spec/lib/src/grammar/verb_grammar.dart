import 'scanner.dart';
import 'segment.dart';

/// A declarative grammar for one atProtocol verb: a leading verb literal
/// followed by an ordered list of [Segment]s. [parse] reproduces the exact
/// output of the legacy `RegExp(VerbSyntax.<verb>, caseSensitive: false)` +
/// `regex_util.processMatches` path: a map keyed by every declared group name,
/// null when the group did not participate, '' for empty-capture flags.
class VerbGrammar {
  /// The literal that opens the command (e.g. `from`, `update:meta`). Matched
  /// case-insensitively. Includes any fixed sub-command prefix.
  final String prefix;

  final List<Segment> segments;

  /// Whether the source regex is anchored at the end (`$`). A handful of verb
  /// regexes (notify:list, notify:remove) have no trailing `$`, so they accept
  /// a matching prefix and ignore any trailing bytes — those set this false.
  final bool anchored;

  VerbGrammar(this.prefix, this.segments, {this.anchored = true});

  late final Set<String> fieldNames = {
    for (final s in segments) ...s.fieldNames,
  };

  /// Parse [command], or return null if it does not match (the caller treats
  /// null as the regex's "no match" — i.e. InvalidSyntaxException).
  Groups? parse(String command) {
    final out = <String, String?>{for (final n in fieldNames) n: null};
    final c = Scanner(command);
    if (!c.matchLiteralCI(prefix)) return null;
    final ok = matchSequence(segments, 0, c, out, () => anchored ? c.atEnd : true);
    return ok ? out : null;
  }
}
