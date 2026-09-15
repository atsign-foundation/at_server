import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^llookup(:(?<operation>meta|all))?(:cached)?`
/// `(:((?<publicScope>public)|(@(?<forAtSign>[^:@\s]+))))?`
/// `:(?<atKey>[^:]((?!:{2})[^@])+)@(?<atSign>[^:@\s]+)$`
final llookupGrammar = VerbGrammar('llookup', [
  Field('operation', leader: ':', rule: enumRule(['meta', 'all']), optional: true),
  OptLit(':cached'),
  PublicOrForAtSign('publicScope', 'forAtSign'),
  Field('atKey', leader: ':', rule: keyNoDoubleColonNoAt),
  Field('atSign', leader: '@', rule: tokenNoColonAtSpace),
]);
