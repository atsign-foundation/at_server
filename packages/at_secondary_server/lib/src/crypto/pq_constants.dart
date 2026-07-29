/// PQ key-record naming and algorithm identifiers — single source of truth for
/// [PqKeyManager], the server's `_protectedKeys` set, the FROM/POL handshake,
/// and tests.
///
/// The keypair is exactly two records, mirroring
/// `signing_publickey`/`signing_privatekey`: the secret half under `local:`,
/// and the public half as the peer-fetchable `public:` record — which doubles
/// as the working copy loaded at boot, so no third record can drift.
///
/// `local:` is never commit-logged (see `hive_at_commit_log.dart`), so never
/// synced, and not addressable via update/delete/lookup/scan. Deliberately not
/// `privatekey:` (a closed enumeration in at_commons' key-type regexes) nor a
/// bare self key (`@atSign:name@atSign`, which IS commit-logged and would sync
/// secret material to enrolled clients).
library;

import 'dart:convert';
import 'dart:typed_data';

/// This server's ML-DSA signing secret key (local, never leaves the server).
String pqSigningSecretKeyName(String atSign) =>
    'local:pq_signing_secretkey$atSign';

/// The public-key record's name, with no visibility prefix and no atSign: the
/// form sent as the `plookup` wire key (the peer's handler prepends `public:`)
/// and matched against `_protectedKeys`.
const String pqSigningPublicKeyRecordName = 'pq_signing_publickey';

/// The published record carrying this server's PQ signing public key(s), and
/// also this server's own copy of it — read back at boot rather than mirrored
/// into a `local:` record, so the published record cannot disagree with what
/// this server signs as. See [buildPqSigningPublicRecord] for the format.
String pqSigningPublicKeyRecordKey(String atSign) =>
    'public:$pqSigningPublicKeyRecordName$atSign';

/// Algorithm identifier for ML-DSA-65 (FIPS 204). Used as the JSON map key in
/// the published record and in the `pq:<algo>:` cookie marker.
const String pqAlgoMlDsa65 = 'ml-dsa-65';

/// Raw ML-DSA-65 public key and signature sizes (FIPS 204).
///
/// Checked before handing peer-supplied bytes to the at_chops FFI: a
/// wrong-length key makes at_chops throw [StateError], which is not an
/// [AtException] and would escape the POL handler as an internal server error
/// rather than an auth failure.
const int mlDsa65PublicKeyLength = 1952;
const int mlDsa65SignatureLength = 3309;

/// PQ signature algorithms this server understands, strongest-first. A prover
/// signs with the first entry it holds a key for; a verifier reads the algo tag
/// off the cookie and looks that key up in the peer's published record.
const List<String> pqSupportedSigningAlgosByPreference = [pqAlgoMlDsa65];

/// Build the [pqSigningPublicKeyRecordKey] payload, e.g.
/// `{"ml-dsa-65": "<base64 public key>"}`. Keying by algorithm rather than
/// storing a bare key is the crypto-agility hook: a future algorithm is an
/// extra entry, never a format break.
String buildPqSigningPublicRecord(Map<String, Uint8List> keysByAlgo) {
  return jsonEncode(
      keysByAlgo.map((algo, key) => MapEntry(algo, base64.encode(key))));
}

/// Extract the public key for [algo] from a [buildPqSigningPublicRecord]
/// payload. Returns `null` if the record is unparseable or has no entry for
/// [algo]; callers read that as "peer can't do this algorithm" and fall back.
Uint8List? pqSigningKeyForAlgo(String json, String algo) {
  try {
    final m = jsonDecode(json) as Map<String, dynamic>;
    final b64 = m[algo];
    if (b64 is! String) return null;
    return base64.decode(b64);
  } catch (_) {
    return null;
  }
}
