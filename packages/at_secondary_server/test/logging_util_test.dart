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

    test('truncates before it escapes', () {
      expect(sanitiseForLogging('\n\n\n\n', cutOffAfter: 2),
          r'\n\n [truncated, 2 more chars]');
    });
  });
}
