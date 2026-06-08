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

  group('isNamespaceAuthorised', () {
    test('configkey carve-out (issue 1570) is always authorised', () {
      expect(isNamespaceAuthorised('configkey', ['nope']), true);
    });

    test('null enrolledNamespace is unrestricted', () {
      expect(isNamespaceAuthorised('phone.wavi@alice', null), true);
    });

    test('empty enrolledNamespace is unrestricted', () {
      expect(isNamespaceAuthorised('phone.wavi@alice', []), true);
    });

    test('atKey without namespace is unrestricted', () {
      expect(isNamespaceAuthorised('@bob:phone@alice', ['buzz']), true);
    });

    test("'*' enrollment is unrestricted", () {
      expect(isNamespaceAuthorised('phone.wavi@alice', ['*']), true);
    });

    test('namespace match — authorised', () {
      expect(isNamespaceAuthorised('phone.buzz@alice', ['buzz']), true);
    });

    test('namespace mismatch — not authorised', () {
      expect(isNamespaceAuthorised('phone.wavi@alice', ['buzz']), false);
    });

    test('invalid atKey — not authorised', () {
      expect(isNamespaceAuthorised('not a key', ['buzz']), false);
    });
  });

  group('shouldIncludeKeyInSyncResponse', () {
    test('regex match + namespace match — included', () {
      expect(
          shouldIncludeKeyInSyncResponse('phone.buzz@alice', 'phone',
              enrolledNamespace: ['buzz']),
          true);
    });

    test('regex miss + always-include — included', () {
      // public top-level key bypasses the regex filter.
      expect(
          shouldIncludeKeyInSyncResponse('public:phone@alice', 'wavi'), true);
    });

    test('regex match + namespace mismatch — not included', () {
      expect(
          shouldIncludeKeyInSyncResponse('phone.wavi@alice', 'phone',
              enrolledNamespace: ['buzz']),
          false);
    });

    test('regex miss + namespace match — not included', () {
      expect(
          shouldIncludeKeyInSyncResponse('phone.buzz@alice', 'email',
              enrolledNamespace: ['buzz']),
          false);
    });
  });
}
