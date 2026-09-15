import '../scanner.dart';
import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^lookup:(bypassCache:(?<bypassCache>true|false):)?`
/// `((?<operation>meta|all):)?(?<atKey>(?:[^:]).+)@(?<atSign>[^:@\s]+)$`
final lookupGrammar = VerbGrammar('lookup:', [
  Field('bypassCache',
      leader: 'bypassCache:', trailer: ':', rule: boolRule, optional: true),
  Field('operation', trailer: ':', rule: enumRule(['meta', 'all']), optional: true),
  // (?:[^:]).+  — first char non-colon, then greedy `.+`; give back so the
  // trailing @atSign (which contains no '@') matches to end.
  GreedyField('atKey', firstPred: notColon, min: 2),
  Field('atSign', leader: '@', rule: tokenNoColonAtSpace),
]);
