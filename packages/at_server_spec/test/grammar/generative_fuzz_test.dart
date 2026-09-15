import 'dart:math';

import 'package:at_commons/at_commons.dart' hide StringBuffer;
import 'package:at_server_spec/grammar.dart';
import 'package:test/test.dart';

import 'equivalence_harness.dart';

/// Generative differential testing: assemble random-but-valid commands from the
/// grammar's own field structure (heavy on the shared metadataFragment), then
/// also mutate them, asserting the lexer and the regex agree on every one.

const _iso = '2024-01-02T03:04:05Z';

// (wire label, value generator) for each metadataFragment field, in regex order.
final _metaFields = <(String, String Function(Random))>[
  ('ttl', _int),
  ('ttb', _int),
  ('ttr', _int),
  ('ccd', _bool),
  ('cAt', (_) => _iso),
  ('uAt', (_) => _iso),
  ('eAt', (_) => _iso),
  ('aAt', (_) => _iso),
  ('dataSignature', _token),
  ('sharedKeyStatus', _token),
  ('isBinary', _bool),
  ('isEncrypted', _bool),
  ('sharedKeyEnc', _token),
  ('pubKeyCS', _token),
  ('pubKeyHash', _token),
  ('hashingAlgo', _token),
  ('encoding', _token),
  ('encKeyName', _token),
  ('encAlgo', _token),
  ('ivNonce', _token),
  ('skeEncKeyName', _token),
  ('skeEncAlgo', _token),
  ('immutable', _bool),
  ('appMetadata', _token),
];

String _int(Random r) => '${r.nextBool() ? '-' : ''}${r.nextInt(100000)}';
String _bool(Random r) => r.nextBool() ? 'true' : 'false';
String _token(Random r) {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
      '/+=._-';
  final n = 1 + r.nextInt(12);
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

String _key(Random r) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789._-';
  final n = 1 + r.nextInt(10);
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

String _metaFragment(Random r) {
  final buf = StringBuffer();
  for (final (label, gen) in _metaFields) {
    if (r.nextInt(3) == 0) {
      buf.write(':$label:${gen(r)}');
    }
  }
  return buf.toString();
}

String _scope(Random r) => r.nextBool() ? ':public' : ':@bob${r.nextInt(9)}';

String _genUpdate(Random r) {
  if (r.nextInt(5) == 0) return 'update:json:{"k":"${_token(r)}"}';
  final nc = r.nextBool() ? ':nc' : '';
  final meta = _metaFragment(r);
  final scope = _scope(r);
  final key = _key(r);
  final at = r.nextBool() ? '@alice${r.nextInt(9)}' : '';
  final value = _token(r);
  return 'update$nc$meta$scope:$key$at $value';
}

String _genNotify(Random r) {
  final buf = StringBuffer('notify');
  if (r.nextBool()) buf.write(':id:id-${r.nextInt(9999)}');
  if (r.nextBool()) buf.write(r.nextBool() ? ':update' : ':delete');
  if (r.nextBool()) buf.write(r.nextBool() ? ':messageType:key' : ':messageType:text');
  if (r.nextBool()) {
    buf.write(':priority:${['low', 'medium', 'high'][r.nextInt(3)]}');
  }
  if (r.nextBool()) buf.write(r.nextBool() ? ':strategy:all' : ':strategy:latest');
  if (r.nextBool()) buf.write(':latestN:${r.nextInt(9)}');
  if (r.nextBool()) buf.write(':notifier:${_token(r)}');
  if (r.nextBool()) buf.write(':ttln:${r.nextInt(99999)}');
  buf.write(_metaFragment(r));
  buf.write(_scope(r));
  buf.write(':${_key(r)}');
  if (r.nextBool()) buf.write('@alice${r.nextInt(9)}');
  if (r.nextBool()) buf.write(':${_token(r)}');
  return buf.toString();
}

/// Mutate a command in a way that often (not always) breaks it, to exercise
/// reject-parity between lexer and regex.
String _mutate(Random r, String cmd) {
  if (cmd.isEmpty) return cmd;
  switch (r.nextInt(4)) {
    case 0: // drop a random colon
      final idx = cmd.indexOf(':', r.nextInt(cmd.length));
      return idx < 0 ? cmd : cmd.substring(0, idx) + cmd.substring(idx + 1);
    case 1: // inject a stray '@'
      final i = r.nextInt(cmd.length);
      return '${cmd.substring(0, i)}@${cmd.substring(i)}';
    case 2: // truncate
      return cmd.substring(0, r.nextInt(cmd.length));
    default: // inject a space
      final i = r.nextInt(cmd.length);
      return '${cmd.substring(0, i)} ${cmd.substring(i)}';
  }
}

void main() {
  final verbs = <String, (String, String Function(Random))>{
    'update': (VerbSyntax.update, _genUpdate),
    'notify': (VerbSyntax.notify, _genNotify),
  };

  verbs.forEach((verb, spec) {
    final (regex, gen) = spec;
    final g = verbGrammars[verb]!;

    test('$verb: 2000 generated valid commands', () {
      final r = Random(0xA75E + verb.hashCode);
      for (var i = 0; i < 2000; i++) {
        expectEquivalent(g, regex, gen(r));
      }
    });

    test('$verb: 2000 mutated commands (reject parity)', () {
      final r = Random(0xB33F + verb.hashCode);
      for (var i = 0; i < 2000; i++) {
        expectEquivalent(g, regex, _mutate(r, gen(r)));
      }
    });
  });
}
