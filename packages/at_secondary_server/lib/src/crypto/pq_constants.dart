/// Single source of truth for PQ key-record naming and algorithm identifiers —
/// used by [PqKeyManager], the server's `_protectedKeys` set, the FROM/POL
/// handshake, and tests.
///
/// Local-only records live under the `local:` namespace: never commit-logged
/// (see `hive_at_commit_log.dart`), so never synced, and not addressable via
/// update/delete/lookup/scan verbs. This is deliberately not `privatekey:` —
/// that prefix is a closed enumeration validated by at_commons' key-type
/// regexes — nor a bare self key (`@atSign:name@atSign`), which IS
/// commit-logged and syncs to enrolled clients, leaking PQ secret material.
///
/// Only [pqSigningPublicKeyRecordName] is peer-fetchable (`public:`); the
/// signing secret/public key pair under `local:` never leaves this server.
library;

/// This server's ML-DSA signing secret key (local, never leaves the server).
String pqSigningSecretKeyName(String atSign) =>
    'local:pq_signing_secretkey$atSign';

/// This server's ML-DSA signing public key (local working copy).
String pqSigningPublicKeyName(String atSign) =>
    'local:pq_signing_publickey$atSign';

/// Entity part of the peer-fetchable signing public-key record, without the
/// `public:` prefix. Used to build the bare `plookup` wire key (the remote
/// verb handler prepends `public:` itself).
const String pqSigningPublicKeyRecordNamePart = 'pq_signing_publickey';

/// The peer-fetchable, published record carrying this server's PQ signing
/// public key(s). A JSON map keyed by algorithm id — see
/// `pq_signing_public_record.dart` — so new signature algorithms can be added
/// as extra entries without a breaking format change (crypto agility).
String pqSigningPublicKeyRecordName(String atSign) =>
    'public:$pqSigningPublicKeyRecordNamePart$atSign';

/// Algorithm identifier for ML-DSA-65 (FIPS 204). Used as the JSON map key in
/// the published record and in the `pq:<algo>:` wire/cookie marker.
const String pqAlgoMlDsa65 = 'ml-dsa-65';

/// PQ signature algorithms this server understands, strongest-first. A prover
/// signs with the first entry it holds a key for; a verifier reads the algo
/// tag off the cookie and looks that key up in the peer's published record.
/// Add a new algorithm by extending this list — no other structural change.
const List<String> pqSupportedSigningAlgosByPreference = [pqAlgoMlDsa65];
