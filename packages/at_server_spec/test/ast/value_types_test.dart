import 'package:at_server_spec/ast.dart';
import 'package:test/test.dart';

void main() {
  group('KeyScope', () {
    test('value equality', () {
      expect(const PublicScope(), const PublicScope());
      expect(const SharedWithScope('bob'), const SharedWithScope('bob'));
      expect(const SharedWithScope('bob'),
          isNot(equals(const SharedWithScope('alice'))));
      expect(const PublicScope(), isNot(equals(const SharedWithScope('bob'))));
    });
  });

  group('MetadataFragment', () {
    final at = DateTime.utc(2026, 1, 2, 3, 4, 5);
    // One non-default value per field, in wire order.
    final values = <String, MetadataFragment>{
      'ttl': const MetadataFragment(ttl: 0),
      'ttb': const MetadataFragment(ttb: -1),
      'ttr': const MetadataFragment(ttr: -1),
      'ccd': const MetadataFragment(ccd: false),
      'createdAt': MetadataFragment(createdAt: at),
      'updatedAt': MetadataFragment(updatedAt: at),
      'expiresAt': MetadataFragment(expiresAt: at),
      'availableAt': MetadataFragment(availableAt: at),
      'dataSignature': const MetadataFragment(dataSignature: 's'),
      'sharedKeyStatus': const MetadataFragment(sharedKeyStatus: 's'),
      'isBinary': const MetadataFragment(isBinary: false),
      'isEncrypted': const MetadataFragment(isEncrypted: false),
      'sharedKeyEnc': const MetadataFragment(sharedKeyEnc: 's'),
      'pubKeyCS': const MetadataFragment(pubKeyCS: 's'),
      'pubKeyHash': const MetadataFragment(pubKeyHash: 's'),
      'hashingAlgo': const MetadataFragment(hashingAlgo: 's'),
      'encoding': const MetadataFragment(encoding: 's'),
      'encKeyName': const MetadataFragment(encKeyName: 's'),
      'encAlgo': const MetadataFragment(encAlgo: 's'),
      'ivNonce': const MetadataFragment(ivNonce: 's'),
      'skeEncKeyName': const MetadataFragment(skeEncKeyName: 's'),
      'skeEncAlgo': const MetadataFragment(skeEncAlgo: 's'),
      'immutable': const MetadataFragment(immutable: false),
      'appMetadata': const MetadataFragment(appMetadata: 's'),
    };

    test('covers all 24 wire tags', () {
      expect(values, hasLength(24));
    });

    test('empty fragment', () {
      expect(const MetadataFragment().isEmpty, isTrue);
      expect(const MetadataFragment(), const MetadataFragment());
    });

    test('an explicit falsy/zero value is distinct from an absent tag', () {
      values.forEach((field, fragment) {
        expect(fragment.isEmpty, isFalse, reason: field);
        expect(fragment, isNot(equals(const MetadataFragment())),
            reason: '$field should affect ==');
      });
    });

    test('fields are not confused with each other', () {
      // ttl:-1 vs ttb:-1 vs ttr:-1 etc. must all differ.
      final list = values.values.toList();
      for (var i = 0; i < list.length; i++) {
        for (var j = i + 1; j < list.length; j++) {
          expect(list[i], isNot(equals(list[j])));
        }
      }
    });
  });
}
