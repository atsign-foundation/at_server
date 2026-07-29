import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_utils/at_logger.dart';

/// Manages this server's ML-DSA-65 signing keypair for post-quantum
/// inter-server authentication.
///
/// FROM/POL auth is a signature challenge-response: the verifier issues a
/// fresh verifier-bound challenge (see [SecondaryUtil.buildBoundPolChallenge]),
/// the prover signs it via [buildChallengeResponse], and the verifier checks it
/// against the prover's published public key (published by [init]). Exactly the
/// legacy RSA handshake with the signature primitive swapped — no KEM, cert,
/// expiry, or rotation machinery.
class PqKeyManager {
  static final _log = AtSignLogger('PqKeyManager');

  late Uint8List _mlDsaSecretKey;
  late Uint8List _mlDsaPublicKey;

  Uint8List get mlDsaPublicKey => _mlDsaPublicKey;

  bool _initialized = false;
  Future<void>? _initFuture;

  /// Whether [init] completed successfully. The outbound handshake checks this
  /// before calling [buildChallengeResponse], so a failed or absent init falls
  /// back to legacy RSA instead of throwing [StateError] mid-handshake.
  bool get isInitialised => _initialized;

  /// Load the ML-DSA signing keypair from [keyStore] or generate a fresh one,
  /// then publish its public half so peers can verify our signatures. Load and
  /// publish are one step by design: [isInitialised] flips only once the key is
  /// both in memory and published, so a publish failure can never leave this
  /// server signing cookies no peer can verify.
  ///
  /// The in-flight [Future] is cached rather than a boolean flag, so concurrent
  /// callers await the same attempt instead of returning early.
  Future<void> init(
      String atSign, AtKeyValueStore<String, AtData, AtMetaData?> keyStore) {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit(atSign, keyStore);
  }

  Future<void> _doInit(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    try {
      final storedSecret =
          await _tryGet(keyStore, pqSigningSecretKeyName(atSign));
      final publishedRecord =
          await _tryGet(keyStore, pqSigningPublicKeyRecordKey(atSign));
      final publishedKey = publishedRecord == null
          ? null
          : pqSigningKeyForAlgo(publishedRecord, pqAlgoMlDsa65);

      if (storedSecret != null && publishedKey != null) {
        // Loading the public half back out of the published record — rather
        // than a private mirror — is what guarantees this server never signs
        // with a key peers can't fetch. Nothing left to publish.
        _mlDsaSecretKey = base64.decode(storedSecret);
        _mlDsaPublicKey = publishedKey;
        _log.info('Loaded existing ML-DSA signing keypair for $atSign');
      } else {
        if (storedSecret != null || publishedRecord != null) {
          _log.warning('Partial/missing ML-DSA key material for $atSign — '
              'regenerating keypair');
        }
        final kp = await MlDsa65KeyPair.generate();
        _mlDsaSecretKey = kp.privateKeyBytes;
        _mlDsaPublicKey = kp.publicKeyBytes;
        await keyStore.put(pqSigningSecretKeyName(atSign),
            AtData()..data = base64.encode(_mlDsaSecretKey));
        _log.info('Generated new ML-DSA signing keypair for $atSign');
        // Publish before flipping _initialized: OutboundClient gates PQ
        // signing on isInitialised alone, so publishing later would emit
        // cookies for an unfetchable key instead of falling back to RSA.
        await _publishPublicKey(atSign, keyStore);
      }
      _initialized = true;
    } finally {
      _initFuture = null;
    }
  }

  /// Publish the signing public key at [pqSigningPublicKeyRecordKey] so peers
  /// can verify our handshake signatures. Called only from [_doInit]'s generate
  /// path; the load path read [_mlDsaPublicKey] out of this very record, so
  /// writing it back would only add a no-op sync delta on every boot.
  ///
  /// No [AtMetaData], unlike update-verb records: no `ttl`/`ttb` because the
  /// keypair does not expire and a lapsed record would silently drop every peer
  /// to RSA; no `ttr` because peers re-fetch every handshake, so a regenerated
  /// keypair takes effect immediately.
  ///
  /// As a `public:` record this is commit-logged and syncs to enrolled clients
  /// — harmless for a public key; the secret half is `local:` (see
  /// [pq_constants]).
  Future<void> _publishPublicKey(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    final record = buildPqSigningPublicRecord({pqAlgoMlDsa65: _mlDsaPublicKey});
    await keyStore.put(
        pqSigningPublicKeyRecordKey(atSign), AtData()..data = record);
    _log.info('Published PQ signing public key for $atSign');
  }

  /// Sign [challenge] and build the cookie the verifier fetches at POL:
  /// `pq:<algo>:<base64 signature>`. The `pq:` prefix marks PQ mode; the algo
  /// tag names the published key to verify against.
  ///
  /// Signs [challenge] verbatim, as the legacy RSA path does: it is already
  /// verifier-bound (see [SecondaryUtil.buildBoundPolChallenge]) and
  /// verification is already scoped to this prover's published key, so the
  /// signed bytes need no further structure.
  Future<String> buildChallengeResponse(String challenge) async {
    _assertInitialized();
    final sig = await AtPqc.mlDsa65
        .signBytes(utf8.encode(challenge), secretKey: _mlDsaSecretKey);
    return 'pq:$pqAlgoMlDsa65:${base64.encode(sig)}';
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  void _assertInitialized() {
    if (!_initialized) throw StateError('PqKeyManager not initialised');
  }

  /// Normalizes both ways an [AtKeyValueStore] impl can report a missing key —
  /// `null` or a not-found exception — to `null`.
  ///
  /// Anything else is logged at `severe`, because the caller reads `null` as
  /// "no key material" and regenerates: a silently swallowed transient store
  /// fault would rotate this server's signing identity and break verification
  /// for every peer holding the old published key.
  Future<String?> _tryGet(
      AtKeyValueStore<String, AtData, AtMetaData?> ks, String key) async {
    try {
      return (await ks.get(key))?.data;
    } on KeyNotFoundException {
      return null;
    } catch (e) {
      _log.severe('Error retrieving key $key — treating as absent, which will '
          'regenerate and overwrite the signing keypair: ${e.toString()}');
      return null;
    }
  }
}
