import 'package:test/test.dart';

import 'pkam_utils.dart';

/// ⚠️ WIRE PIN: the pkam verb's two spellings, as raw literals.
void main() {
  test('a legacy pkam carries the digest alone', () {
    expect(pkamCommand('c2lnbmF0dXJl', null), 'pkam:c2lnbmF0dXJl');
  });

  test('an enrolled pkam names the enrollment ahead of the digest', () {
    expect(pkamCommand('c2lnbmF0dXJl', '7f3a1b2c-enrollment'),
        'pkam:enrollmentId:7f3a1b2c-enrollment:c2lnbmF0dXJl');
  });
}
