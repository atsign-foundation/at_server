import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart';
import 'package:at_secondary/src/utils/apkam_signature_verifier.dart';
import 'package:crypton/crypton.dart';
import 'package:elliptic/elliptic.dart' as elliptic;
import 'package:test/test.dart';

/// The verifier is the single boundary both `pkam:` and `enroll:update` reach
/// APKAM signature verification through, so it is tested against every
/// algorithm the `pkam:` grammar accepts — not just the one the rest of the
/// suite happens to sign with.
///
/// That gap is the whole reason this file exists: every APKAM test in the
/// package signed `rsa2048`, which at_chops verifies synchronously, so a
/// verification path that returned an unawaited `Future<bool>` for `mldsa65`
/// sat green through a full unit suite and died on the wire.
void main() {
  final message = Uint8List.fromList(utf8.encode('a-session@alice:a-secret'));
  final otherMessage =
      Uint8List.fromList(utf8.encode('a-session@alice:a-different-secret'));

  group('rsa2048', () {
    late RSAKeypair keyPair;
    late String publicKey;
    late String signature;

    setUpAll(() {
      keyPair = RSAKeypair.fromRandom();
      publicKey = keyPair.publicKey.toString();
      signature =
          base64Encode(keyPair.privateKey.createSHA256Signature(message));
    });

    test('a genuine signature verifies', () async {
      expect(
          await ApkamSignatureVerifier.verify(
            message: message,
            base64Signature: signature,
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.rsa2048,
          ),
          true);
    });

    test('the same signature over different bytes does not', () async {
      expect(
          await ApkamSignatureVerifier.verify(
            message: otherMessage,
            base64Signature: signature,
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.rsa2048,
          ),
          false);
    });

    test('a signature by a different key does not', () async {
      final impostor = RSAKeypair.fromRandom();
      expect(
          await ApkamSignatureVerifier.verify(
            message: message,
            base64Signature: base64Encode(
                impostor.privateKey.createSHA256Signature(message)),
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.rsa2048,
          ),
          false);
    });
  });

  group('ecc_secp256r1', () {
    // ECC had no coverage at all before this file, and it is the algorithm
    // least like the others: at_chops spells its public key as hex and its
    // signature as compact-hex code units rather than bytes, so it is the one
    // most likely to break under a change to how the verifier frames things.
    late elliptic.PrivateKey privateKey;
    late String publicKey;
    late String signature;

    String signWith(elliptic.PrivateKey key, Uint8List data) {
      final algo = EccSigningAlgo()..privateKey = key;
      return base64Encode(algo.sign(data));
    }

    setUpAll(() {
      privateKey = elliptic.getSecp256r1().generatePrivateKey();
      publicKey = privateKey.publicKey.toHex();
      signature = signWith(privateKey, message);
    });

    test('a genuine signature verifies', () async {
      expect(
          await ApkamSignatureVerifier.verify(
            message: message,
            base64Signature: signature,
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.ecc_secp256r1,
          ),
          true);
    });

    test('the same signature over different bytes does not', () async {
      expect(
          await ApkamSignatureVerifier.verify(
            message: otherMessage,
            base64Signature: signature,
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.ecc_secp256r1,
          ),
          false);
    });

    test('a signature by a different key does not', () async {
      final impostor = elliptic.getSecp256r1().generatePrivateKey();
      expect(
          await ApkamSignatureVerifier.verify(
            message: message,
            base64Signature: signWith(impostor, message),
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.ecc_secp256r1,
          ),
          false);
    });
  });

  group('mldsa65', () {
    // The algorithm at_chops verifies ASYNCHRONOUSLY. If the verifier ever
    // stops awaiting, these are the tests that go red rather than the wire.
    late ({Uint8List publicKey, Uint8List secretKey}) keyPair;
    late String publicKey;
    late String signature;

    setUpAll(() async {
      keyPair = await MlDsa65PureDartAlgo().generateKeyPair();
      publicKey = base64Encode(keyPair.publicKey);
      signature = base64Encode(await MlDsa65PureDartAlgo()
          .signBytes(message, secretKey: keyPair.secretKey));
    });

    test('a genuine signature verifies', () async {
      expect(
          await ApkamSignatureVerifier.verify(
            message: message,
            base64Signature: signature,
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.mldsa65,
          ),
          true);
    });

    test('the same signature over different bytes does not', () async {
      expect(
          await ApkamSignatureVerifier.verify(
            message: otherMessage,
            base64Signature: signature,
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.mldsa65,
          ),
          false);
    });

    test('a signature by a different key does not', () async {
      final impostor = await MlDsa65PureDartAlgo().generateKeyPair();
      expect(
          await ApkamSignatureVerifier.verify(
            message: message,
            base64Signature: base64Encode(await MlDsa65PureDartAlgo()
                .signBytes(message, secretKey: impostor.secretKey)),
            publicKey: publicKey,
            signingAlgo: SigningAlgoType.mldsa65,
          ),
          false);
    });

    test('answers exactly what the AtChops path it replaced answered',
        () async {
      // mldsa65 is the ONE algorithm this verifier routes to a different
      // at_chops API (the stateless verifyBytes) instead of the compatibility
      // AtChopsImpl.verify that rsa2048 and ecc_secp256r1 still use. So it is
      // the one where equivalence has to be observed rather than reasoned
      // about: AtChopsImpl for mldsa65 selects MlDsa65PureDartAlgo and calls
      // its deprecated verify(), whose entire body is base64Decode(publicKey)
      // followed by verifyBytes — this asserts that instead of trusting it.
      Future<bool> throughAtChops(Uint8List msg, String base64Sig) async {
        final input =
            AtSigningVerificationInput(msg, base64Decode(base64Sig), publicKey)
              ..signingAlgoType = SigningAlgoType.mldsa65
              ..hashingAlgoType = HashingAlgoType.sha256
              ..signingMode = AtSigningMode.pkam;
        return await AtChopsImpl(AtChopsKeys.create(null, null))
            .verify(input)
            .result;
      }

      final impostor = await MlDsa65PureDartAlgo().generateKeyPair();
      final wrongKeySignature = base64Encode(await MlDsa65PureDartAlgo()
          .signBytes(message, secretKey: impostor.secretKey));

      // Both polarities, so the agreement below cannot be two paths that
      // happen to answer false to everything.
      final cases = <({Uint8List msg, String sig, bool expected})>[
        (msg: message, sig: signature, expected: true),
        (msg: otherMessage, sig: signature, expected: false),
        (msg: message, sig: wrongKeySignature, expected: false),
      ];

      for (final c in cases) {
        final viaVerifier = await ApkamSignatureVerifier.verify(
          message: c.msg,
          base64Signature: c.sig,
          publicKey: publicKey,
          signingAlgo: SigningAlgoType.mldsa65,
        );
        expect(viaVerifier, c.expected);
        expect(viaVerifier, await throughAtChops(c.msg, c.sig),
            reason: 'the new path must answer exactly what the old one did');
      }
    });

    test('verify() answers a real bool, not a Future the caller must unwrap',
        () async {
      // The regression pin. `expect(result, true)` above would also catch it,
      // but only by accident of how Future compares to true — this says what
      // is actually being guarded, so a later reader does not "simplify" the
      // await away.
      final Object result = await ApkamSignatureVerifier.verify(
        message: message,
        base64Signature: signature,
        publicKey: publicKey,
        signingAlgo: SigningAlgoType.mldsa65,
      );
      expect(result, isA<bool>());
      expect(result, isNot(isA<Future>()));
    });
  });

  group('algorithm token resolution', () {
    // Raw literals deliberately: these tokens are the wire vocabulary, shared
    // with at_client and recorded on enrollment records. Asserting them against
    // the constants that define them would follow a rename silently.
    test('the pkam: grammar tokens resolve to their algorithms', () {
      expect(ApkamSignatureVerifier.signingAlgoTypeOf('rsa2048'),
          SigningAlgoType.rsa2048);
      expect(ApkamSignatureVerifier.signingAlgoTypeOf('ecc_secp256r1'),
          SigningAlgoType.ecc_secp256r1);
      expect(ApkamSignatureVerifier.signingAlgoTypeOf('mldsa65'),
          SigningAlgoType.mldsa65);
    });

    test('an absent or unknown token means rsa2048', () {
      // What a PKAM message predating the field meant, and what an enrollment
      // record written before it carried one still means.
      expect(ApkamSignatureVerifier.signingAlgoTypeOf(null),
          SigningAlgoType.rsa2048);
      expect(ApkamSignatureVerifier.signingAlgoTypeOf('ed25519'),
          SigningAlgoType.rsa2048);
    });

    test('hashing tokens resolve, defaulting to sha256', () {
      expect(ApkamSignatureVerifier.hashingAlgoTypeOf('sha256'),
          HashingAlgoType.sha256);
      expect(ApkamSignatureVerifier.hashingAlgoTypeOf('sha512'),
          HashingAlgoType.sha512);
      expect(ApkamSignatureVerifier.hashingAlgoTypeOf(null),
          HashingAlgoType.sha256);
    });
  });
}
