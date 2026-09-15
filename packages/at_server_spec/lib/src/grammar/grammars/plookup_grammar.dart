import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^plookup:(bypassCache:(?<bypassCache>true|false):)?`
/// `((?<operation>meta|all):)?(?<atKey>[^@\s]+)@(?<atSign>[^:@\s]+)$`
final plookupGrammar = VerbGrammar('plookup:', [
  Field('bypassCache',
      leader: 'bypassCache:', trailer: ':', rule: boolRule, optional: true),
  Field('operation', trailer: ':', rule: enumRule(['meta', 'all']), optional: true),
  Field('atKey', rule: tokenNoAtSpace),
  Field('atSign', leader: '@', rule: tokenNoColonAtSpace),
]);
