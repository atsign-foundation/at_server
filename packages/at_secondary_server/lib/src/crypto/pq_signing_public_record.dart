import 'dart:convert';
import 'dart:typed_data';

/// Serialisation for the peer-fetchable PQ signing public-key record
/// (`public:pq_signing_publickey@atsign`).
///
/// The record is a JSON object keyed by algorithm id, e.g.
/// `{"ml-dsa-65": "<base64 public key>"}`. Keying by algorithm — rather than
/// storing a single bare key — is the crypto-agility hook: a future signature
/// algorithm is published as an additional entry, and the format never breaks.
/// A verifier reads the algorithm tag off the handshake cookie and looks that
/// entry up here.

/// Build the JSON record from public keys keyed by algorithm id.
String buildPqSigningPublicRecord(Map<String, Uint8List> keysByAlgo) {
  return jsonEncode(
      keysByAlgo.map((algo, key) => MapEntry(algo, base64.encode(key))));
}

/// Extract the public key for [algo] from a record produced by
/// [buildPqSigningPublicRecord]. Returns `null` if the record is unparseable
/// or carries no key for [algo] — callers treat that as "peer can't do this
/// algorithm" and fall back.
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
