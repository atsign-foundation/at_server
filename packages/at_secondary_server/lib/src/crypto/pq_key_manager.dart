import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/crypto/pq_signing_public_record.dart';
import 'package:at_utils/at_logger.dart';

/// Manages this server's ML-DSA-65 signing keypair for post-quantum
/// inter-server authentication.
///
/// Inter-server FROM/POL auth is a signature challenge-response: the verifier
/// issues a fresh, verifier-bound pol challenge (see
/// [SecondaryUtil.buildBoundPolChallenge] — the same challenge format the
/// legacy RSA path signs), the prover signs it with this keypair via
/// [buildChallengeResponse], and the verifier fetches the prover's published
/// public key (published by [init]) and checks the signature. This is the
/// exact shape of the legacy RSA handshake with the signature primitive
/// swapped for a post-quantum one — no KEM, cert, expiry, or rotation
/// machinery.
class PqKeyManager {
  static final _log = AtSignLogger('PqKeyManager');

  late Uint8List _mlDsaSecretKey;
  late Uint8List _mlDsaPublicKey;

  Uint8List get mlDsaPublicKey => _mlDsaPublicKey;

  bool _initialized = false;
  Future<void>? _initFuture;

  /// Whether [init] has completed successfully. The outbound handshake checks
  /// this before calling [buildChallengeResponse]; if init never ran or failed, the
  /// prover cleanly falls back to the legacy RSA signature path instead of
  /// surfacing a [StateError] mid-handshake.
  bool get isInitialised => _initialized;

  /// Load the existing ML-DSA signing keypair from [keyStore] or generate a
  /// fresh one, then publish its public half so peers can verify this
  /// server's handshake signatures. Loading/generating and publishing are one
  /// atomic step, not two the caller sequences: [isInitialised] only becomes
  /// true once the key is both in memory and published, so a publish failure
  /// can never leave this server signing PQ cookies peers have no way to
  /// verify.
  ///
  /// Concurrent callers share a single in-flight attempt: the started
  /// [Future] is cached (rather than short-circuited by a boolean flag) so a
  /// second caller awaits the same result instead of returning immediately
  /// while the first call is still in progress.
  Future<void> init(
      String atSign, AtKeyValueStore<String, AtData, AtMetaData?> keyStore) {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit(atSign, keyStore);
  }

  Future<void> _doInit(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    try {
      final secKeyName = pqSigningSecretKeyName(atSign);
      final pubKeyName = pqSigningPublicKeyName(atSign);

      // fetch existing keys
      final existingSec = await _tryGet(keyStore, secKeyName);
      final existingPub = await _tryGet(keyStore, pubKeyName);

      bool keyWasGenerated = false;
      if (existingSec != null && existingPub != null) {
        // load existing keys
        _mlDsaSecretKey = base64.decode(existingSec);
        _mlDsaPublicKey = base64.decode(existingPub);
        _log.info('Loaded existing ML-DSA signing keypair for $atSign');
      } else {
        // generate new keys
        if (existingSec != null || existingPub != null) {
          _log.warning('Partial/missing ML-DSA key material for $atSign — '
              'regenerating keypair');
        }
        final kp = await MlDsa65KeyPair.generate();
        _mlDsaSecretKey = kp.privateKeyBytes;
        _mlDsaPublicKey = kp.publicKeyBytes;
        await keyStore.put(
            secKeyName, AtData()..data = base64.encode(_mlDsaSecretKey));
        await keyStore.put(
            pubKeyName, AtData()..data = base64.encode(_mlDsaPublicKey));
        _log.info('Generated new ML-DSA signing keypair for $atSign');
        keyWasGenerated = true;
      }
      // Publish before flipping _initialized: OutboundClient gates PQ
      // signing on isInitialised alone, so if this write failed but
      // _initialized were already true, this server would keep emitting PQ
      // cookies for a key it never actually published — peers could never
      // verify them, and the handshake would break instead of falling back
      // to RSA.
      //
      // Skipped on an ordinary restart with an unchanged, still-published
      // key: the record is `public:` and commit-logged, so an unconditional
      // publish here would write an identical value on every boot and push a
      // no-op sync delta to every enrolled client. Only publish when the
      // keypair changed (freshly generated) or the stored record doesn't
      // already match it (withdrawn, corrupted, or manually touched) — a
      // peer must never be left unable to verify against what's published.
      if (keyWasGenerated ||
          await _publishedRecordNeedsRefresh(atSign, keyStore)) {
        await _publishPublicKey(atSign, keyStore);
      }
      _initialized = true;
    } finally {
      _initFuture = null;
    }
  }

  /// Whether the record currently published at [pqSigningPublicKeyRecordName]
  /// is missing or differs from what [_mlDsaPublicKey] would produce.
  ///
  /// Any read failure (not just a missing key) is treated as "needs
  /// (re-)publishing": a peer that can't fetch a matching record can't verify
  /// us either way, so republishing is the safe default rather than silently
  /// leaving a stale/absent record in place.
  Future<bool> _publishedRecordNeedsRefresh(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    final existing =
        await _tryGet(keyStore, pqSigningPublicKeyRecordName(atSign));
    if (existing == null) return true;
    return existing != buildPqSigningPublicRecord({pqAlgoMlDsa65: _mlDsaPublicKey});
  }

  /// Publish this server's signing public key at
  /// [pqSigningPublicKeyRecordName] as a JSON map keyed by algorithm id, so
  /// peers can fetch it to verify handshake signatures. Called only from
  /// [_doInit], and only when needed (see
  /// [_publishedRecordNeedsRefresh]) — publishing is not a step callers
  /// sequence separately, since a loaded/generated keypair is useless to
  /// peers until it is published.
  ///
  /// Written with no [AtMetaData] — deliberately, unlike records created via
  /// the update verb:
  /// - No `ttl`/`ttb`: the record must stay valid for as long as the keypair
  ///   does, and the keypair does not expire. An expiring record would make
  ///   every peer silently fall back to RSA the moment it lapsed.
  /// - No `ttr`: peers re-fetch on every handshake rather than caching, so a
  ///   regenerated keypair takes effect immediately.
  ///
  /// Being a `public:` record it is commit-logged and therefore syncs to
  /// enrolled clients. That is harmless — it is a public key, and the secret
  /// half lives under `local:` which never syncs (see [pq_constants]).
  Future<void> _publishPublicKey(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    final record = buildPqSigningPublicRecord({pqAlgoMlDsa65: _mlDsaPublicKey});
    await keyStore.put(
        pqSigningPublicKeyRecordName(atSign), AtData()..data = record);
    _log.info('Published PQ signing public key for $atSign');
  }

  /// Sign a handshake [challenge] with this server's ML-DSA secret key and
  /// build the cookie value the verifier fetches at POL:
  /// `pq:<algo>:<base64 signature>`. The `pq:` prefix marks PQ mode and the
  /// algo tag tells the verifier which published public key to check against.
  ///
  /// Signs [challenge] verbatim, exactly as the legacy RSA path does —
  /// [challenge] is already verifier-bound (see
  /// [SecondaryUtil.buildBoundPolChallenge]), and verification is already
  /// scoped to this prover's own published key, so no further structure is
  /// needed in the signed bytes.
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

  /// `get` may return `null` for a missing key or throw a backend-specific
  /// not-found exception depending on the concrete [AtKeyValueStore] impl —
  /// normalize both cases to `null`.
  ///
  /// Anything that is *not* a not-found is logged at `severe`: the caller
  /// reads a `null` here as "no key material exists" and responds by
  /// generating a fresh keypair and overwriting the stored one. If a
  /// transient store fault were to reach that path silently, this server
  /// would rotate its signing identity without anyone noticing, and every
  /// peer holding the old published key would start failing verification.
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
