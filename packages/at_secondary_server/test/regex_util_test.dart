import 'package:at_secondary/src/utils/regex_util.dart';
import 'package:test/test.dart';

void main() {
  group('alwaysIncludeInSync', () {
    test('encryption public key — included', () {
      expect(alwaysIncludeInSync('public:publickey@alice'), true);
    });

    test('top-level public key without namespace — included', () {
      expect(alwaysIncludeInSync('public:phone@alice'), true);
    });

    test('public key WITH namespace — not blanket-included', () {
      expect(alwaysIncludeInSync('public:phone.wavi@alice'), false);
    });

    test('private namespaced key — not blanket-included', () {
      expect(alwaysIncludeInSync('phone.wavi@alice'), false);
    });
  });
}
