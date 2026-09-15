import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^pkam:(signingAlgo:(?<signingAlgo>ecc_secp256r1|rsa2048|mldsa65):)?`
/// `(hashingAlgo:(?<hashingAlgo>sha256|sha512):)?`
/// `(enrollmentId:(?<enrollmentId>.+):)?(?<signature>.+$)`
final pkamGrammar = VerbGrammar('pkam:', [
  Field('signingAlgo',
      leader: 'signingAlgo:',
      trailer: ':',
      rule: enumRule(['ecc_secp256r1', 'rsa2048', 'mldsa65']),
      optional: true),
  Field('hashingAlgo',
      leader: 'hashingAlgo:',
      trailer: ':',
      rule: enumRule(['sha256', 'sha512']),
      optional: true),
  GreedyField('enrollmentId',
      leader: 'enrollmentId:', trailer: ':', optional: true),
  GreedyField('signature'),
]);
