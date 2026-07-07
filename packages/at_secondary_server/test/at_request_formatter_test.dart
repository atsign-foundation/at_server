import 'package:at_secondary/src/connection/outbound/at_request_formatter.dart';
import 'package:test/test.dart';

void main() {
  group('AtRequestFormatter', () {
    test('createToRequest emits to:@target with a trailing newline', () {
      expect(AtRequestFormatter.createToRequest('@bob🛠'), 'to:@bob🛠\n');
    });

    test('createFromRequest is unchanged (bare from:, no to:)', () {
      expect(
          AtRequestFormatter.createFromRequest('@alice🛠'), 'from:@alice🛠\n');
    });

    test('createLookUpRequest is unchanged', () {
      expect(AtRequestFormatter.createLookUpRequest('all:publickey@bob🛠'),
          'lookup:all:publickey@bob🛠\n');
    });

    test('createPolRequest is unchanged', () {
      expect(AtRequestFormatter.createPolRequest(), 'pol\n');
    });
  });
}
