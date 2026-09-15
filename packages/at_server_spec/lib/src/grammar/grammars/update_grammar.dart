import '../metadata_fragment.dart';
import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^update(:nc(?<noCommit>))?(`
/// `  :json:(?<json>.+)`
/// `  | <metadataFragment>(:((?<publicScope>public)|(@(?<forAtSign>[^:@\s]+))))?`
/// `    :(?<atKey>(([^:@\s]+)|(privatekey:at_pkam_publickey)))`
/// `    (@(?<atSign>[^:@\s]+))? (?<value>.+)`
/// `)$`
final updateGrammar = VerbGrammar('update', [
  Flag('noCommit', ':nc'),
  Alt([
    [Field('json', leader: ':json:', rule: restRule)],
    [
      ...metadataFragment(),
      PublicOrForAtSign('publicScope', 'forAtSign'),
      Lit(':'),
      Alt([
        [Field('atKey', rule: tokenNoColonAtSpace)],
        [Field('atKey', rule: literal('privatekey:at_pkam_publickey'))],
      ]),
      Field('atSign', leader: '@', rule: tokenNoColonAtSpace, optional: true),
      Field('value', leader: ' ', rule: restRule),
    ],
  ]),
]);
