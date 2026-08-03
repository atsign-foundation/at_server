import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/crypto/pol_signing_algos.dart';
import 'package:at_secondary/src/crypto/signing_key_constants.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';

/// Covers the signing-algorithm registry itself: that each entry round-trips,
/// that malformed peer material (attacker-controlled: public key, signature)
/// fails verification rather than throwing, that malformed local material
/// (this server's own secret key) throws [AtSigningException] rather than
/// silently truncating, that non-base64 material of any kind raises
/// [FormatException] (all of which callers turn into an auth failure rather
/// than an internal error), and that the registry's ordering and lookup
/// contracts hold.
void main() {
  group('wire/storage boundaries — the id must not silently drift', () {
    // Deliberately spelled as a literal on the right-hand side of every
    // assertion below, never derived from [polAlgoMlDsa65] on both sides: a
    // rename of the constant would otherwise still agree with itself and pass.
    // Boundary 2 (the published record's top-level key) is the one that fails
    // silently downstream — chooseNegotiatedAlgo finds no match, `alg` is
    // omitted, and every handshake degrades to RSA with no exception logged.
    // This test is what stands between that and CI passing.
    test('boundary 1 — Hive secret-key name', () {
      expect(signingSecretKeyName(polAlgoMlDsa65, '@alice'),
          'local:signing_secretkey.ml-dsa-65@alice');
    });

    test('boundary 2 — published record top-level key', () {
      final record = buildSigningPublicKeysRecord({polAlgoMlDsa65: 'k'});
      expect((jsonDecode(record) as Map).keys, contains('ml-dsa-65'));
    });

    test('boundary 3 — alg field inside the signed pol1. challenge', () {
      final challenge = SecondaryUtil.buildBoundPolChallenge(
          '@alice'.toAtsign(),
          chosenAlgo: polAlgoMlDsa65);
      expect(SecondaryUtil.decodeBoundPolChallenge(challenge)!.chosenAlgo,
          'ml-dsa-65');
    });

    test('boundary 4 — cookie tag', () {
      expect(buildSignedCookie(polAlgoMlDsa65, 'sig'), 'ml-dsa-65:sig');
    });
  });

  group('registry contracts', () {
    test('ids are colon-free and non-empty', () {
      // Uniqueness is a language guarantee of Map keys, not something to
      // assert here — a duplicate id could not have been inserted at all.
      for (final id in negotiableSigningAlgos.keys) {
        expect(id, isNotEmpty);
        expect(id.contains(':'), isFalse,
            reason: 'the cookie is split on the first colon, so an id '
                'containing one would be unparseable');
      }
    });

    test('lookup finds every entry and rejects unknown ids', () {
      for (final entry in negotiableSigningAlgos.entries) {
        expect(negotiableSigningAlgos[entry.key], same(entry.value));
      }
      expect(negotiableSigningAlgos['no-such-algo'], isNull);
      expect(negotiableSigningAlgos[''], isNull);
    });

    test('legacy RSA is not an entry — it is the fallback, never negotiated',
        () {
      expect(negotiableSigningAlgos.containsKey(polAlgoRsaSha256), isFalse,
          reason: 'RSA differs in every dimension the registry models '
              '(untagged cookie, own record, boot-owned keypair), so it is '
              'verified by verifyLegacyRsaSignature on an explicit branch');
    });

    test('every registry entry is negotiable', () {
      expect(negotiableSigningAlgos.keys.toList(), equals([polAlgoMlDsa65]));
    });
  });

  group('ml-dsa-65', () {
    final algo = negotiableSigningAlgos[polAlgoMlDsa65]!;

    test('generate → sign → verify round-trips', () async {
      final kp = await algo.generateKeyPairB64();
      final sig = await algo.signB64('a-challenge', kp.secretKey);
      expect(await algo.verifyB64('a-challenge', sig, kp.publicKey), isTrue);
    });

    test('a signature does not verify against a different challenge', () async {
      final kp = await algo.generateKeyPairB64();
      final sig = await algo.signB64('challenge-one', kp.secretKey);
      expect(await algo.verifyB64('challenge-two', sig, kp.publicKey), isFalse);
    });

    test('generated key material matches the FIPS 204 raw sizes', () async {
      // Literals, not the impl's own constants — this pins the spec values so
      // a typo in them cannot agree with itself and pass.
      final kp = await algo.generateKeyPairB64();
      expect(base64.decode(kp.publicKey).length, equals(1952));
      final sig = await algo.signB64('x', kp.secretKey);
      expect(base64.decode(sig).length, equals(3309));
    });

    test('wrong-length public key fails verification, does not throw',
        () async {
      // at_chops treats a wrong-length public key or signature as
      // attacker-controlled wire input: verifyBytes returns false rather than
      // throwing. pol_verb_handler.dart then takes the "signature invalid"
      // branch instead of "could not be verified" — same UnAuthenticatedException,
      // different message.
      final kp = await algo.generateKeyPairB64();
      final sig = await algo.signB64('x', kp.secretKey);
      final truncated = base64.encode(base64.decode(kp.publicKey).sublist(0, 8));
      expect(await algo.verifyB64('x', sig, truncated), isFalse);
    });

    test('wrong-length signature fails verification, does not throw',
        () async {
      final kp = await algo.generateKeyPairB64();
      expect(
          await algo.verifyB64('x', base64.encode([1, 2, 3]), kp.publicKey),
          isFalse);
    });

    test('wrong-length secret key throws AtSigningException, not silent '
        'truncation', () async {
      // The secret key is trusted local input (this server's own keystore
      // value), so at_chops validates it before at_chops-pure-Dart would
      // otherwise sign with a truncated prefix and produce a signature no peer
      // could verify, with nothing in the logs.
      final tooShort = base64.encode(utf8.encode('too-short'));
      await expectLater(algo.signB64('x', tooShort),
          throwsA(isA<AtSigningException>()));
    });

    test('non-base64 material throws FormatException', () async {
      final kp = await algo.generateKeyPairB64();
      final sig = await algo.signB64('x', kp.secretKey);
      await expectLater(
          algo.verifyB64('x', sig, 'not-base64!!'), throwsA(isA<FormatException>()));
      await expectLater(algo.verifyB64('x', 'not-base64!!', kp.publicKey),
          throwsA(isA<FormatException>()));
      await expectLater(algo.signB64('x', 'not-base64!!'),
          throwsA(isA<FormatException>()));
    });
  });

  group('legacy RSA verification', () {
    final kp = RSAKeypair.fromRandom();

    /// Mirrors what a legacy prover sends: SecondaryUtil.signChallenge, which
    /// is what every deployed atServer already does.
    String legacySign(String challenge) =>
        SecondaryUtil.signChallenge(challenge, kp.privateKey.toString());

    test('verifies a signature a legacy prover would produce', () async {
      expect(
          await verifyLegacyRsaSignature(
              'a-challenge', legacySign('a-challenge'), kp.publicKey.toString()),
          isTrue);
    });

    test('rejects a signature made with a different key', () async {
      final other = RSAKeypair.fromRandom();
      expect(
          await verifyLegacyRsaSignature('a-challenge',
              legacySign('a-challenge'), other.publicKey.toString()),
          isFalse);
    });

    test('rejects a signature over a different challenge', () async {
      expect(
          await verifyLegacyRsaSignature(
              'other-challenge', legacySign('a-challenge'), kp.publicKey.toString()),
          isFalse);
    });

    test('malformed public key throws FormatException rather than escaping',
        () async {
      await expectLater(
          verifyLegacyRsaSignature('x', legacySign('x'), 'not-a-key'),
          throwsA(isA<FormatException>()),
          reason: 'this previously surfaced as an internal server error out of '
              'RSAPublicKey.fromString');
    });

    test('non-base64 signature throws FormatException', () async {
      await expectLater(
          verifyLegacyRsaSignature('x', 'not-base64!!', kp.publicKey.toString()),
          throwsA(isA<FormatException>()));
    });

    test('signing trims the challenge, verification does not — preserved '
        'deliberately for wire compatibility', () async {
      // Deployed atServers sign trim()ed bytes. Pinned here so the asymmetry
      // cannot be "tidied up" without a failing test explaining why.
      expect(legacySign('  abc  '), equals(legacySign('abc')),
          reason: 'signChallenge trims, so padded and bare sign alike');
      final sig = legacySign('  abc  ');
      expect(await verifyLegacyRsaSignature('abc', sig, kp.publicKey.toString()),
          isTrue);
      expect(
          await verifyLegacyRsaSignature(
              '  abc  ', sig, kp.publicKey.toString()),
          isFalse,
          reason: 'verification does NOT trim — the asymmetry being pinned');
    });
  });
}
