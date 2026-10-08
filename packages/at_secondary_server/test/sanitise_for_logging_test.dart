import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:test/test.dart';

void main() {
  group('BaseSocketConnection.sanitiseForLogging', () {
    test('leaves printable text alone', () {
      expect(BaseSocketConnection.sanitiseForLogging('lookup:phone@alice ✓'),
          'lookup:phone@alice ✓');
    });

    test('escapes a line break and a carriage return', () {
      expect(BaseSocketConnection.sanitiseForLogging('zz\nyy\r'), r'zz\nyy\r');
    });

    test('escapes ESC and tab', () {
      expect(BaseSocketConnection.sanitiseForLogging('a\x1b[2Jb\tc'),
          r'a\x1b[2Jb\tc');
    });

    test('escapes NUL, DEL and the C1 controls', () {
      expect(BaseSocketConnection.sanitiseForLogging('\x00\x7f\x85\x9b\xa0'),
          '\\x00\\x7f\\x85\\x9b\xa0');
    });

    test('truncates before it escapes', () {
      expect(
          BaseSocketConnection.sanitiseForLogging('\n\n\n\n', cutOffAfter: 2),
          r'\n\n [truncated, 2 more chars]');
    });
  });
}
