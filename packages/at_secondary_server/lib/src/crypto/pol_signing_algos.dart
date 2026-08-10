import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:crypton/crypton.dart';

/// The signature algorithms the FROM/POL handshake can negotiate — one entry
/// per *challenge type*.
///
/// The map key is the single identifier used everywhere that type appears:
/// the top-level key in the published `signing_publickeys` record, the
/// cookie tag (`<id>:<base64 signature>`), and the `alg` field inside the
/// signed pol challenge. It is at_server's own wire protocol, chosen
/// independently of whatever at_chops calls the algorithm internally.
///
/// Adding an algorithm is one entry in [negotiableSigningAlgos] — no handler,
/// key-manager or record-format change.
///
/// ## Malformed input
///
/// [Base64Signing.signB64]/[Base64Signing.verifyB64] throw [FormatException]
/// for base64 that will not decode. Beyond that, at_chops validates:
/// [AtSignatureAlgorithm.signBytes] throws `AtSigningException` for a
/// wrong-length secret key (trusted local input — see
/// `SigningKeyManager`'s load-time pairing check), while
/// [AtSignatureAlgorithm.verifyBytes] returns `false`, never throwing, for a
/// wrong-length public key or signature (attacker-controlled wire input).
/// Callers funnel all of these into one authentication failure: peer-supplied
/// garbage is not a server fault.
extension Base64Signing on AtSignatureAlgorithm {
  /// Generate a fresh keypair, both halves base64.
  Future<({String publicKey, String secretKey})> generateKeyPairB64() async {
    final kp = await generateKeyPair();
    return (
      publicKey: base64.encode(kp.publicKey),
      secretKey: base64.encode(kp.secretKey),
    );
  }

  /// Sign [challenge], returning the base64 signature that goes in the cookie
  /// after the `<id>:` tag.
  Future<String> signB64(String challenge, String secretKeyB64) async {
    final sig = await signBytes(utf8.encode(challenge),
        secretKey: _decode(secretKeyB64, 'secret key'));
    return base64.encode(sig);
  }

  /// Verify a base64 [signatureB64] over [challenge] against [publicKeyB64].
  Future<bool> verifyB64(
      String challenge, String signatureB64, String publicKeyB64) async {
    final pk = _decode(publicKeyB64, 'public key');
    final sig = _decode(signatureB64, 'signature');
    return verifyBytes(utf8.encode(challenge), signature: sig, publicKey: pk);
  }

  Uint8List _decode(String b64, String what) {
    try {
      return base64.decode(b64);
    } on FormatException {
      throw FormatException('$what is not valid base64');
    }
  }
}

/// Challenge-type identifiers. Kept as named constants because they appear in
/// the record, the cookie and the signed challenge, and a typo in any one of
/// those is a silent fallback to RSA rather than a compile error.
///
/// [polAlgoMlDsa65] is at_server's own wire protocol — the top-level key in
/// the published `signing_publickeys` record, the cookie tag, and the `alg`
/// field inside signed pol challenges — not a property of at_chops. It is
/// deliberately declared as a plain literal here, keyed alongside the
/// algorithm in [negotiableSigningAlgos], rather than read off
/// `AtSignatureAlgorithm`: at_chops' own identity for the algorithm is free
/// to change (or disappear) across branches without this id, or anything
/// already published under it, moving.
const String polAlgoMlDsa65 = 'ml-dsa-65';
const String polAlgoRsaSha256 = 'rsa-sha256';

/// Bare entity name of the legacy RSA signing public key record. Predates this
/// registry and is published unconditionally for pre-PQ peers, so it is never
/// duplicated into `signing_publickeys`.
const String legacyRsaSigningPublicKeyRecordName = 'signing_publickey';

/// Verify a legacy, untagged RSA-2048/SHA-256 cookie — the pre-PQ handshake
/// signature, and what a peer sends when nothing better was negotiated.
///
/// Deliberately *not* a registry entry, and not representable as one: RSA here
/// implements only the deprecated, sealed `AtSigningAlgorithm`, not
/// [AtSignatureAlgorithm]. Legacy RSA also differs from a negotiable type in
/// every other dimension the registry models: its cookie is untagged, its key
/// lives at its own [legacyRsaSigningPublicKeyRecordName] record, and its
/// keypair is created during server boot rather than by `SigningKeyManager`.
///
/// Throws [FormatException] for unusable signature or key material, matching
/// [Base64Signing]'s contract so the caller funnels both into one auth
/// failure. Note this does *not* `trim()` the challenge while
/// [SecondaryUtil.signChallenge] does — an asymmetry preserved deliberately,
/// since every deployed atServer signs trimmed bytes today and "fixing" it
/// would break verification against un-upgraded peers. Harmless in practice:
/// challenges are UUIDs or whitespace-free `pol1.` tokens.
Future<bool> verifyLegacyRsaSignature(
    String challenge, String signatureB64, String publicKey) async {
  final Uint8List sig;
  try {
    sig = base64.decode(signatureB64);
  } on FormatException {
    throw FormatException('$polAlgoRsaSha256 signature is not valid base64');
  }
  final RSAPublicKey key;
  try {
    key = RSAPublicKey.fromString(publicKey);
  } catch (e) {
    // crypton throws assorted ASN.1/format errors on junk; normalise so the
    // caller sees one failure mode. Previously these were left uncaught,
    // surfacing a malformed peer key as an internal server error.
    throw FormatException(
        '$polAlgoRsaSha256 public key could not be parsed: $e');
  }
  return key.verifySHA256Signature(utf8.encode(challenge), sig);
}

/// Every negotiable type this server understands, id → algorithm,
/// **strongest first**. Preference *is* insertion order — Dart map literals
/// preserve it — so a prover signs with the first entry the verifier demanded
/// and for which it holds a key.
///
/// The id lives beside the algorithm here rather than being read off it, so
/// this registry is the one place a challenge-type id is assigned.
///
/// Legacy RSA is absent by design — it is the fallback when nothing here
/// matched, so it is neither advertised nor negotiated.
///
/// `Map.unmodifiable` keeps it immutable at runtime — preference order is
/// security-relevant and nothing may reorder or shrink it while the process
/// runs. Tests that need a second entry inject one via
/// `SigningKeyManager.withAlgos` rather than mutating this map; see
/// `pol_signing_algos_test.dart` and `outbound_client_pq_signing_test.dart`.
final Map<String, AtSignatureAlgorithm> negotiableSigningAlgos =
    Map.unmodifiable({polAlgoMlDsa65: AtPqc.mlDsa65});
