import 'at_protocol_grammar.dart';
import 'segment.dart';
import 'verb_grammar.dart';

/// The public, canonical atProtocol parser — the lexer-based replacement for
/// `RegExp(VerbSyntax.<verb>)` parsing. Behaviour is identical to the legacy
/// regex path: it returns a map keyed by every declared group name (null when
/// absent, '' for empty-capture flags), or null when the command does not match
/// (which the server surfaces as an InvalidSyntaxException).
class AtProtocolLexer {
  const AtProtocolLexer();

  /// Parse [command] as a known [verb] (the server drop-in for `getVerbParam`,
  /// keyed by `Verb.name()`). Returns null when no grammar is registered for
  /// [verb] or the command does not match.
  Groups? parseAs(String verb, String command) =>
      verbGrammars[verb]?.parse(command);

  /// The grammar registered for [verb], if any.
  VerbGrammar? grammarForVerb(String verb) => verbGrammars[verb];

  /// Whether a grammar has been ported for [verb] yet (used to gate the
  /// opt-in server switch verb-by-verb during migration).
  bool supports(String verb) => verbGrammars.containsKey(verb);
}
