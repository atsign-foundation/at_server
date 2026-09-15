import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/grammar.dart';
import 'package:test/test.dart';

import 'equivalence_harness.dart';

void main() {
  group('structural: grammar field names == regex named groups', () {
    test('from', () {
      expect(verbGrammars['from']!.fieldNames,
          equals(namedGroupsOf(VerbSyntax.from)));
    });
    test('pkam', () {
      expect(verbGrammars['pkam']!.fieldNames,
          equals(namedGroupsOf(VerbSyntax.pkam)));
    });
  });

  group('from equivalence', () {
    final g = verbGrammars['from']!;
    final commands = <String>[
      'from:@alice',
      'from:alice',
      'from:@alice🦄', // unicode
      'from:@alice:clientConfig:{"version":"3.0.57"}',
      'from:alice:clientConfig:{"a":"b","c":{"d":1}}',
      // negatives
      'from:',
      'from:@al ice',
      'from:@alice:clientConfig:notjson',
      'from:@alice:clientConfig:{"x":"y"',
      'from:@al:ice',
      'notfrom:@alice',
      'from',
    ];
    for (final c in commands) {
      test(_name(c), () => expectEquivalent(g, VerbSyntax.from, c));
    }
  });

  group('pkam equivalence', () {
    final g = verbGrammars['pkam']!;
    final commands = <String>[
      'pkam:abcd1234',
      'pkam:signingAlgo:rsa2048:hashingAlgo:sha256:someSignatureValue',
      'pkam:signingAlgo:ecc_secp256r1:hashingAlgo:sha512:sig==',
      'pkam:signingAlgo:mldsa65:sig',
      'pkam:hashingAlgo:sha256:sig',
      'pkam:enrollmentId:abc-123:theSignature',
      'pkam:signingAlgo:rsa2048:enrollmentId:abc-123:sig',
      'pkam:enrollmentId:has:colons:in:it:sig',
      'pkam:signingAlgo:rsa2048:hashingAlgo:sha512:enrollmentId:e1:s1',
      // negatives
      'pkam:',
      'pkam:signingAlgo:badalgo:sig',
      'notpkam:sig',
    ];
    for (final c in commands) {
      test(_name(c), () => expectEquivalent(g, VerbSyntax.pkam, c));
    }
  });
}

String _name(String c) => c.length > 60 ? '${c.substring(0, 57)}...' : c;
