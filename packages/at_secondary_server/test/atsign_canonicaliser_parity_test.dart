import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_utils.dart';
import 'package:test/test.dart';

/// [canonicalise]'s result for [input]: the atSign it gives, or the message
/// it refuses with.
String verdict(String input, String Function(String) canonicalise) {
  try {
    return 'atSign ${canonicalise(input)}';
  } on InvalidAtSignException catch (e) {
    return 'refused: ${e.message}';
  }
}

String toAtsign(String input) => input.toAtsign();

String fixAtSign(String input) => AtUtils.fixAtSign(input);

String repeated(int count, String character) =>
    List.filled(count, character).join();

void main() {
  final inputs = <String>[
    'alice',
    '@alice',
    '@Alice',
    'ALICE',
    '@a.l.i.c.e',
    '@.alice.',
    '@colin.constable',
    'phone.wavi@alice',
    'phone@alice.bob',
    '@\u{1F600}',
    '@a\u{FE0F}',
    '@❤\u{FE0F}',
    '@été',
    '@İstanbul',
    '',
    '@',
    '@...',
    '@@a',
    '@a@b',
    '@a b',
    '@a\tb',
    '@a\nb',
    '@a\u0000b',
    '@a\u007fb',
    '@a␀b',
    '@a b',
    '@a　b',
    for (final c in r"!*'`();:&=+$,/?#[]{}".split('')) '@a${c}b',
    for (final count in [1, 54, 55]) '@${repeated(count, 'a')}',
    '@${repeated(55, 'A')}',
    '@${List.filled(55, 'a').join('.')}',
    '@${repeated(55, '\u{1F600}')}',
    'key.name@${repeated(55, 'a')}',
  ];

  group('Given an input of at most 55 characters after its @', () {
    test(
        'when at_commons and at_utils each canonicalise it, '
        'then they give the same atSign or refuse it with the same message',
        () {
      for (final input in inputs) {
        expect(verdict(input, toAtsign), verdict(input, fixAtSign),
            reason: 'input ${input.runes.toList()}');
      }
    });
  });

  group('Given an input of 56 characters after its @', () {
    test(
        'when at_commons and at_utils each canonicalise it, '
        'then only at_commons refuses it', () {
      final input = '@${repeated(56, 'a')}';
      expect(verdict(input, toAtsign),
          'refused: invalid @sign: must have at most 55 characters after the @');
      expect(verdict(input, fixAtSign), 'atSign $input');
    });
  });
}
