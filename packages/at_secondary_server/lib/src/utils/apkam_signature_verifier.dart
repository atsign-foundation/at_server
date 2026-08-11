import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart';
import 'package:at_utils/at_logger.dart';

/// APKAM signature verification for the whole atServer, behind one type.
///
/// Two verbs verify an APKAM signature: `pkam:` authenticates a connection
/// against the key recorded on its enrollment, and `enroll:update` proves the
/// sender holds the private half of a key it is asking to install. The two
/// have to agree byte-for-byte about how a signature is framed — a key that
/// can authenticate must also be installable, and vice versa — so they share
/// this one path rather than each assembling at_chops calls of its own.
///
/// The return type is the substance of that sharing. at_chops answers a
/// verification through `AtSigningResult.result`, a `dynamic` holding a
/// `FutureOr<bool>`: `rsa2048` and `ecc_secp256r1` verify synchronously,
/// `mldsa65` does not. Reading that field straight into a `bool` compiles
/// clean, passes an rsa2048-only test suite, and throws
/// `type 'Future<bool>' is not a subtype of type 'bool'` the first time a
/// post-quantum key authenticates — which is what shipped, at both sites, and
/// what no test could see while every test signed with RSA. A `Future<bool>`
/// here is the same promise made in a form the analyzer enforces, and no
/// caller meets the `dynamic` again.
class ApkamSignatureVerifier {
  ApkamSignatureVerifier._();

  static final AtSignLogger _logger = AtSignLogger('ApkamSignatureVerifier');

  /// The `signingAlgo` tokens the `pkam:` grammar accepts, spelled as they
  /// travel on the wire and as they are recorded on an enrollment.
  static const String eccAlgo = 'ecc_secp256r1';
  static const String rsa2048Algo = 'rsa2048';
  static const String mlDsa65Algo = 'mldsa65';

  static const String sha256Algo = 'sha256';
  static const String sha512Algo = 'sha512';

  /// The [SigningAlgoType] a `signingAlgo` token names.
  ///
  /// An absent or unrecognised token resolves to `rsa2048`: that is what a
  /// PKAM message predating the field meant, and what an enrollment record
  /// written before it carried one still means.
  static SigningAlgoType signingAlgoTypeOf(String? signingAlgo) =>
      switch (signingAlgo) {
        eccAlgo => SigningAlgoType.ecc_secp256r1,
        // Without this branch a post-quantum APKAM keypair falls through to
        // the RSA default and can never authenticate at all — the signature is
        // well formed, just interpreted under the wrong algorithm.
        mlDsa65Algo => SigningAlgoType.mldsa65,
        _ => SigningAlgoType.rsa2048,
      };

  /// The [HashingAlgoType] a `hashingAlgo` token names; SHA-256 by default.
  static HashingAlgoType hashingAlgoTypeOf(String? hashingAlgo) =>
      switch (hashingAlgo) {
        sha512Algo => HashingAlgoType.sha512,
        _ => HashingAlgoType.sha256,
      };

  /// True when [base64Signature] was produced over [message] by the private
  /// half of [publicKey], under [signingAlgo].
  ///
  /// [publicKey] is spelled the way its algorithm spells it — base64 X.509 for
  /// `rsa2048`, hex for `ecc_secp256r1`, base64 raw for `mldsa65` — because
  /// that is how it is stored on the enrollment record and how it arrives on
  /// the wire.
  ///
  /// Never throws. Every argument is chosen by whoever is trying to
  /// authenticate, so "this did not verify" is the honest answer to every
  /// shape of bad input, including a signature that is not valid base64 —
  /// which previously escaped both call sites as an uncaught [FormatException]
  /// because each decoded before entering its guard.
  static Future<bool> verify({
    required Uint8List message,
    required String base64Signature,
    required String publicKey,
    required SigningAlgoType signingAlgo,
    HashingAlgoType hashingAlgo = HashingAlgoType.sha256,
  }) async {
    try {
      final Uint8List signature = base64Decode(base64Signature);

      if (signingAlgo == SigningAlgoType.mldsa65) {
        // Straight to the stateless interface, whose verifyBytes is declared
        // Future<bool> — so the one algorithm that verifies asynchronously
        // never travels as a dynamic at all. This is what AtChopsImpl does for
        // mldsa65 anyway: it selects MlDsa65PureDartAlgo, then calls the
        // deprecated verify(), whose entire body is base64Decode(publicKey)
        // followed by this same verifyBytes.
        return await MlDsa65PureDartAlgo().verifyBytes(message,
            signature: signature, publicKey: base64Decode(publicKey));
      }

      // rsa2048 and ecc_secp256r1 stay on the compatibility API deliberately.
      // RsaSignatureAlgo refuses any modulus that is not exactly 2048 bits,
      // which PkamSigningAlgo does not, so adopting it would stop an
      // enrollment holding an off-size RSA key from authenticating; and
      // at_chops has no AtSignatureAlgorithm for ECC at all — an ECC public
      // key is hex and its signature is compact-hex code units, neither of
      // which fits verifyBytes' Uint8List parameters. Both are changes to what
      // verifies on the authentication path, which is not a refactor's to
      // make.
      final input = AtSigningVerificationInput(message, signature, publicKey)
        ..signingAlgoType = signingAlgo
        ..hashingAlgoType = hashingAlgo
        // pkam, not data: AtSigningMode.data signs with the ENCRYPTION
        // keypair, and what is proved here is possession of an APKAM signing
        // key.
        ..signingMode = AtSigningMode.pkam;
      return await AtChopsImpl(AtChopsKeys.create(null, null))
          .verify(input)
          .result;
    } catch (e, stackTrace) {
      // Total, deliberately. Every argument here is chosen by whoever is
      // trying to authenticate — `enroll:update` takes the public key straight
      // off the request — and at_chops' backends reject bad input in three
      // different ways: an AtSigningVerificationException, a FormatException
      // out of base64Decode, and, for ecc_secp256r1, a bare thrown String from
      // package:elliptic that `on Exception` does not catch at all (plus a
      // RangeError for a hex key shorter than two characters). A malformed key
      // has to fail the authentication, not escape the verb handler.
      //
      // An Error is a defect in this server rather than a bad signature, so it
      // is logged at severe with its stack rather than disappearing into
      // finer. Either way this fails closed: nothing is authenticated by a
      // verification that crashed.
      if (e is Error) {
        _logger.severe('APKAM signature verification threw $e\n$stackTrace');
      } else {
        _logger.finer('APKAM signature verification failed: $e');
      }
      return false;
    }
  }
}
