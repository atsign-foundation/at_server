import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:test/test.dart';

void main() {
  group('sanitiseForLogging', () {
    test('leaves printable text alone', () {
      expect(
          sanitiseForLogging('lookup:phone@alice ✓'), 'lookup:phone@alice ✓');
    });

    test('escapes a line break and a carriage return', () {
      expect(sanitiseForLogging('zz\nyy\r'), r'zz\nyy\r');
    });

    test('escapes ESC and tab', () {
      expect(sanitiseForLogging('a\x1b[2Jb\tc'), r'a\x1b[2Jb\tc');
    });

    test('escapes NUL, DEL and the C1 controls', () {
      expect(sanitiseForLogging('\x00\x7f\x85\x9b\xa0'),
          '\\x00\\x7f\\x85\\x9b\xa0');
    });

    test('escapes a backslash, so that every escape is unambiguous', () {
      expect(sanitiseForLogging(r'a\nb'), r'a\\nb');
      expect(sanitiseForLogging('a\nb'), r'a\nb');
    });

    test('cuts what it has escaped, not what it was given', () {
      // 525 escapes of four characters each fill the 2100 exactly.
      expect(sanitiseForLogging('\x1b' * 4000),
          '${r'\x1b' * 525} [truncated, 3475 more chars]');
    });

    test('cuts between escapes, never inside one', () {
      expect(sanitiseForLogging('\n\n\n\n', cutOffAfter: 3),
          r'\n\n [truncated, 2 more chars]');
    });

    test('cuts plain text at the limit', () {
      expect(sanitiseForLogging('abcdef', cutOffAfter: 4),
          'abcd [truncated, 2 more chars]');
    });
  });
}
