import '../metadata_fragment.dart';
import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^update:meta(:nc(?<noCommit>))?`
/// `(:((?<publicScope>public)|(@(?<forAtSign>[^:@\s]+))))?`
/// `:(?<atKey>[^:@]((?!:{2})[^:@])+)@(?<atSign>[^:@\s]+)<metadataFragment>$`
final updateMetaGrammar = VerbGrammar('update:meta', [
  Flag('noCommit', ':nc'),
  PublicOrForAtSign('publicScope', 'forAtSign'),
  Field('atKey', leader: ':', rule: keyNoDoubleColonNoColonAt),
  Field('atSign', leader: '@', rule: tokenNoColonAtSpace),
  ...metadataFragment(),
]);
