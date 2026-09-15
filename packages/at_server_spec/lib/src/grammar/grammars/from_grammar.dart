import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^from:(?<atSign>@?[^:@\s]+)(:clientConfig:(?<clientConfig>\{.+\}))?$`
final fromGrammar = VerbGrammar('from', [
  Field('atSign', leader: ':', rule: atSignOptionalPrefix),
  Field('clientConfig',
      leader: ':clientConfig:', rule: braceJsonRule, optional: true),
]);
