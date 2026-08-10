import 'package:at_secondary/src/crypto/signing_key_constants.dart';
import 'package:test/test.dart';

/// Pure-logic coverage for the verifier-chosen-algorithm decision. This is the
/// one piece of [FromVerbHandler]'s peer-path negotiation that a unit test can
/// exercise directly — the rest of that path needs a real TLS handshake (see
/// `pol_challenge_binding_test.dart`) and is covered by the functional/e2e
/// suites instead.
void main() {
  group('chooseNegotiatedAlgo', () {
    test('picks the strongest of our types that the peer also publishes', () {
      final peerRecord = buildSigningPublicKeysRecord(
          {'weaker-algo': 'weak-key', 'stronger-algo': 'strong-key'});
      expect(chooseNegotiatedAlgo(['stronger-algo', 'weaker-algo'], peerRecord),
          equals((type: 'stronger-algo', publicKey: 'strong-key')));
    });

    test('falls back to the weaker type when only that is mutual', () {
      final peerRecord =
          buildSigningPublicKeysRecord({'weaker-algo': 'weak-key'});
      expect(chooseNegotiatedAlgo(['stronger-algo', 'weaker-algo'], peerRecord),
          equals((type: 'weaker-algo', publicKey: 'weak-key')));
    });

    test('ignores a peer-published type we do not hold, using what we do', () {
      final peerRecord = buildSigningPublicKeysRecord(
          {'some-future-algo': 'future-key', 'weaker-algo': 'weak-key'});
      expect(chooseNegotiatedAlgo(['stronger-algo', 'weaker-algo'], peerRecord),
          equals((type: 'weaker-algo', publicKey: 'weak-key')));
    });

    test('our preference order decides, not the order the peer listed', () {
      // The peer's record lists weaker-algo first; our order still wins.
      final peerRecord = buildSigningPublicKeysRecord(
          {'weaker-algo': 'weak-key', 'stronger-algo': 'strong-key'});
      expect(
          chooseNegotiatedAlgo(['stronger-algo', 'weaker-algo'], peerRecord)
              ?.type,
          equals('stronger-algo'));
    });

    test('no mutual type → null', () {
      final peerRecord = buildSigningPublicKeysRecord({'other-algo': 'k'});
      expect(chooseNegotiatedAlgo(['stronger-algo', 'weaker-algo'], peerRecord),
          isNull);
    });

    test('peer publishes nothing usable (empty/unparseable record) → null', () {
      expect(chooseNegotiatedAlgo(['stronger-algo'], '{}'), isNull);
      expect(
          chooseNegotiatedAlgo(['stronger-algo'], 'not-json-at-all'), isNull);
    });

    test('we hold no negotiable types → null regardless of peer record', () {
      final peerRecord = buildSigningPublicKeysRecord({'any-algo': 'key'});
      expect(chooseNegotiatedAlgo(const [], peerRecord), isNull);
    });
  });
}
