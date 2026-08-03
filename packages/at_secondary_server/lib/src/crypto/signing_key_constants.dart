/// Naming and wire/record formats for FROM/POL handshake signing keys — the
/// single source of truth for `SigningKeyManager`, the server's
/// `_protectedKeys` set, the handshake handlers, and tests.
///
/// ## These formats are meant to be permanent
///
/// Algorithms will change, and much of the fleet is not ours to upgrade, so
/// nothing here is named after an algorithm or an era. There is exactly one
/// published record, generically named, whose top-level keys are challenge
/// types; growing to a new algorithm adds an entry rather than a record.
/// Readers **must** ignore unknown top-level keys and unknown fields inside an
/// entry — that is what keeps future additions (parameter sets, expiry) from
/// being a breaking change.
///
/// Note the division of labour: this record carries *key material only*.
/// Capability — which types a verifier accepts — travels in-band inside the
/// signed pol challenge, where it is tamper-evident. So a type whose key lives
/// at a well-known location needs no entry here at all — RSA's key lives at
/// `signing_publickey` and is verified on `PolVerbHandler`'s explicit legacy
/// branch, via `verifyLegacyRsaSignature`.
///
/// ## Storage visibility
///
/// Secret halves live under `local:`, which is never commit-logged (see
/// `hive_at_commit_log.dart`), therefore never synced, and not addressable via
/// update/delete/lookup/scan. Deliberately not `privatekey:` (a closed
/// enumeration in at_commons' key-type regexes) nor a bare self key
/// (`@atSign:name@atSign`, which IS commit-logged and would sync secret
/// material to enrolled clients).
library;

import 'dart:convert';

/// This server's signing secret key for [type] — local, never leaves the
/// server. Per-type so several coexist: during a migration this server may hold
/// the current algorithm's key *and* a new algorithm's key at the same time.
String signingSecretKeyName(String type, String atSign) =>
    'local:signing_secretkey.$type$atSign';

/// The published record's name: no visibility prefix and no atSign. This is the
/// form sent as the `lookup` wire key (the peer's handler prepends `public:`)
/// and the form matched against `_protectedKeys`.
const String signingPublicKeysRecordName = 'signing_publickeys';

/// The published record carrying this server's signing public keys, and also
/// this server's own copy of them — read back at boot rather than mirrored into
/// a `local:` record, so what this server signs as cannot disagree with what
/// peers can fetch.
String signingPublicKeysRecordKey(String atSign) =>
    'public:$signingPublicKeysRecordName$atSign';

// ── the published record ──────────────────────────────────────────────────

/// Build the record payload from base64 public keys keyed by challenge type:
///
/// ```json
/// {"ml-dsa-65": {"publicKey": "<base64>"}}
/// ```
///
/// Entries are objects rather than bare strings so a future algorithm can carry
/// parameters alongside its key without a format break — the ~20 bytes that
/// buys is why the nesting exists.
String buildSigningPublicKeysRecord(Map<String, String> publicKeysByType) {
  return jsonEncode(
      publicKeysByType.map((type, key) => MapEntry(type, {'publicKey': key})));
}

/// The base64 public key [type] offers in a [buildSigningPublicKeysRecord]
/// payload, or `null` if the record is unparseable, has no entry for [type], or
/// that entry carries no usable `publicKey`.
///
/// Unknown top-level keys and unknown fields within the entry are ignored, so a
/// peer running a newer build that publishes extra types or extra per-entry
/// fields stays readable here. Callers treat `null` as "cannot verify this type"
/// and fail the handshake rather than guessing.
String? signingPublicKeyForType(String json, String type) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final entry = decoded[type];
    if (entry is! Map) return null;
    final key = entry['publicKey'];
    return (key is String && key.isNotEmpty) ? key : null;
  } catch (_) {
    return null;
  }
}

/// The verifier's choice of signature type: the strongest entry in
/// [ourTypesByPreference] (own preference order, strongest first) that also
/// has a usable key in [peerRecordJson] — a peer's published
/// `signing_publickeys` record, as fetched by [FromVerbHandler]. `null` when
/// nothing in [peerRecordJson] matches any type we hold.
///
/// Iterates our own preference order rather than the peer's: which of the
/// peer's published types is strongest is the verifier's judgement to make,
/// not something a peer should be able to steer by reordering its record.
({String type, String publicKey})? chooseNegotiatedAlgo(
    List<String> ourTypesByPreference, String peerRecordJson) {
  for (final type in ourTypesByPreference) {
    final key = signingPublicKeyForType(peerRecordJson, type);
    if (key != null) return (type: type, publicKey: key);
  }
  return null;
}

// ── the pol cookie ────────────────────────────────────────────────────────

/// Frame a signed cookie as `<type>:<base64 signature>`.
///
/// The tag is the same identifier used as this type's key in the published
/// record, so a verifier reads one string off the cookie and knows both how to
/// verify and where to find the key.
String buildSignedCookie(String type, String signatureB64) =>
    '$type:$signatureB64';

/// Split a cookie into its type tag and signature.
///
/// A `null` type means the legacy untagged form: a bare base64 RSA signature,
/// which is what every pre-PQ atServer sends. The discriminator is simply
/// whether a colon is present — the base64 alphabet contains none, so this is
/// unambiguous and needs no sentinel prefix.
///
/// Splits on the *first* colon only. A tag that is empty, or names a type this
/// server does not know, is rejected downstream as an authentication failure;
/// extra colons land in the signature and fail its base64 decode.
({String? type, String signature}) parseSignedCookie(String cookie) {
  final i = cookie.indexOf(':');
  if (i < 0) return (type: null, signature: cookie);
  return (type: cookie.substring(0, i), signature: cookie.substring(i + 1));
}
