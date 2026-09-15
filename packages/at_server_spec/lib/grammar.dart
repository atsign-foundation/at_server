/// The canonical, lexer-based atProtocol grammar — a behaviour-equivalent
/// replacement for the `VerbSyntax` regexes. See `AtProtocolLexer`.
library;

export 'src/grammar/at_protocol_grammar.dart' show verbGrammars;
export 'src/grammar/segment.dart' show Groups;
export 'src/grammar/verb_grammar.dart' show VerbGrammar;
export 'src/grammar/verb_parser.dart' show AtProtocolLexer;
