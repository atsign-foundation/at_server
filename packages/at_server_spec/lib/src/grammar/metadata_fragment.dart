import 'segment.dart';
import 'value_rules.dart';

/// The shared metadata sub-grammar, spliced into `update`, `update:meta` and
/// `notify` — mirroring the `$metadataFragment` interpolation in
/// `VerbSyntax`. Field order MUST match the regex exactly (an out-of-order
/// field simply won't be consumed, leaving a tail that fails the `$` anchor,
/// identical to the regex).
///
/// NOTE: do NOT reuse this for `notify:all` — that verb uses different numeric
/// classes (`\d+` / `-?\d+`) and a colon-terminated layout; its fields are
/// defined locally in its own grammar.
List<Segment> metadataFragment() => [
      _m('ttl', 'ttl', intRule),
      _m('ttb', 'ttb', intRule),
      _m('ttr', 'ttr', intRule),
      _m('ccd', 'ccd', boolRule),
      _m('createdAt', 'cAt', iso8601Rule),
      _m('updatedAt', 'uAt', iso8601Rule),
      _m('expiresAt', 'eAt', iso8601Rule),
      _m('availableAt', 'aAt', iso8601Rule),
      _m('dataSignature', 'dataSignature', tokenNoColonAtSpace),
      _m('sharedKeyStatus', 'sharedKeyStatus', tokenNoColonAtSpace),
      _m('isBinary', 'isBinary', boolRule),
      _m('isEncrypted', 'isEncrypted', boolRule),
      _m('sharedKeyEnc', 'sharedKeyEnc', tokenNoColonAtSpace),
      _m('pubKeyCS', 'pubKeyCS', tokenNoColonAtSpace),
      _m('pubKeyHash', 'pubKeyHash', tokenNoColonAtSpace),
      _m('hashingAlgo', 'hashingAlgo', tokenNoColonAtSpace),
      _m('encoding', 'encoding', tokenNoColonAtSpace),
      _m('encKeyName', 'encKeyName', tokenNoColonAtSpace),
      _m('encAlgo', 'encAlgo', tokenNoColonAtSpace),
      _m('ivNonce', 'ivNonce', tokenNoColonAtSpace),
      _m('skeEncKeyName', 'skeEncKeyName', tokenNoColonAtSpace),
      _m('skeEncAlgo', 'skeEncAlgo', tokenNoColonAtSpace),
      _m('immutable', 'immutable', boolRule),
      _m('appMetadata', 'appMetadata', tokenNoColonAtSpace),
    ];

/// A single optional `:label:value` metadata field.
Field _m(String name, String wireLabel, ValueRule rule) =>
    Field(name, leader: ':$wireLabel:', rule: rule, optional: true);
