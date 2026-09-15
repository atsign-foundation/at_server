import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^delete(:dAt:(?<deletedAt>ISO))?(:nc(?<noCommit>))?(:(?<force>force))?`
/// `(:priority:(?<priority>low|medium|high))?(:cached)?`
/// `(:((?<publicScope>public)|(@(?<forAtSign>[^:@\s]+))))?`
/// `:(?<atKey>(([^:@\s]+)|(privatekey:at_secret)))(@(?<atSign>[^:@\s]+))?$`
final deleteGrammar = VerbGrammar('delete', [
  Field('deletedAt', leader: ':dAt:', rule: iso8601Rule, optional: true),
  Flag('noCommit', ':nc'),
  Field('force', leader: ':', rule: literal('force'), optional: true),
  Field('priority',
      leader: ':priority:',
      rule: enumRule(['low', 'medium', 'high']),
      optional: true),
  OptLit(':cached'),
  PublicOrForAtSign('publicScope', 'forAtSign'),
  Lit(':'),
  Alt([
    [Field('atKey', rule: tokenNoColonAtSpace)],
    [Field('atKey', rule: literal('privatekey:at_secret'))],
  ]),
  Field('atSign', leader: '@', rule: tokenNoColonAtSpace, optional: true),
]);
