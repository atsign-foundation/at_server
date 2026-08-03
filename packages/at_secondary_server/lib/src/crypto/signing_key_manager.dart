import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pol_signing_algos.dart';
import 'package:at_secondary/src/crypto/signing_key_constants.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

/// Manages this server's FROM/POL handshake signing keypairs — one per
/// negotiable challenge type.
///
/// FROM/POL auth is a signature challenge-response: the verifier issues a fresh
/// verifier-bound challenge demanding the one strongest type it and the prover
/// both hold a key for, the prover signs with that type, and the verifier
/// checks the signature against the prover's published public key. Exactly the
/// legacy RSA handshake with the signature primitive made negotiable — no KEM,
/// cert, expiry, or rotation machinery.
///
/// Holds a key for every entry in [negotiableSigningAlgos]; RSA is absent by
/// design, since its keypair is created during boot by `AtSecondaryServerImpl`
/// and its public half is published separately at `signing_publickey` for pre-PQ
/// peers.
class SigningKeyManager {
  static final _log = AtSignLogger('SigningKeyManager');

  /// The registry this manager holds keys for, id → algorithm, in preference
  /// order.
  final Map<String, AtSignatureAlgorithm> _algos;

  /// Production: the process-wide registry.
  SigningKeyManager() : this.withAlgos(negotiableSigningAlgos);

  /// Tests only. at_chops ships exactly one PQ signature algorithm, so without
  /// injection the multi-type behaviour — holding, publishing and signing with
  /// whichever of several types is demanded — would ship entirely unexercised.
  ///
  /// No test may both inject a non-default registry here and exercise
  /// [PolVerbHandler]'s verification path: FROM would then negotiate from the
  /// injected registry while POL resolves against [negotiableSigningAlgos].
  /// In production they are always the same map.
  @visibleForTesting
  SigningKeyManager.withAlgos(this._algos);

  /// Loaded keypairs by challenge type. The algorithm that generated a key
  /// travels with it rather than being re-looked-up in [_algos] at sign time,
  /// so this cannot pair one entry's algorithm with another's key material.
  final Map<String,
      ({AtSignatureAlgorithm algo, String publicKey, String secretKey})>
      _keys = {};

  bool _initialized = false;
  Future<void>? _initFuture;

  /// Whether [init] completed successfully. The outbound handshake checks this
  /// before signing, so a failed or absent init falls back to legacy RSA instead
  /// of throwing mid-handshake.
  bool get isInitialised => _initialized;

  /// Challenge types this server holds a usable key for, in registry preference
  /// order (strongest first). As a verifier, FROM walks this to choose the one
  /// type it demands of a peer; as a prover, this is what we may sign with when
  /// a peer demands one of them.
  ///
  /// Derived from [_algos], not [_keys]' insertion order — preference order is
  /// security-relevant and should not rest on `LinkedHashMap` semantics.
  List<String> get availableTypes => [
        for (final type in _algos.keys)
          if (_keys.containsKey(type)) type
      ];

  /// The base64 public key held for [type], or `null` if none.
  String? publicKeyFor(String type) => _keys[type]?.publicKey;

  /// Load each negotiable type's keypair from [keyStore] or generate a fresh
  /// one, then publish the public halves so peers can verify our signatures.
  ///
  /// Load and publish are one step by design: [isInitialised] flips only once
  /// every key is both in memory and published, so a publish failure can never
  /// leave this server signing cookies no peer can verify.
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
      final publishedRecord =
          await _tryGet(keyStore, signingPublicKeysRecordKey(atSign));

      var needsPublish = false;
      for (final entry in _algos.entries) {
        final type = entry.key;
        final algo = entry.value;
        final storedSecret =
            await _tryGet(keyStore, signingSecretKeyName(type, atSign));
        final publishedKey = publishedRecord == null
            ? null
            : signingPublicKeyForType(publishedRecord, type);

        if (storedSecret != null && publishedKey != null) {
          if (await _pairMatches(algo, storedSecret, publishedKey)) {
            // Reading the public half back out of the published record —
            // rather than a private mirror — is what guarantees this server
            // never signs with a key peers cannot fetch.
            _keys[type] =
                (algo: algo, publicKey: publishedKey, secretKey: storedSecret);
            _log.info('Loaded existing $type signing keypair for $atSign');
            continue;
          }
          _log.severe('Stored $type secret key does not match the published '
              'public key for $atSign — regenerating both halves rather than '
              'signing with a keypair no peer could verify');
        } else if (storedSecret != null || publishedKey != null) {
          _log.warning('Partial/missing $type key material for $atSign — '
              'regenerating keypair');
        }
        final kp = await algo.generateKeyPairB64();
        await keyStore.put(signingSecretKeyName(type, atSign),
            AtData()..data = kp.secretKey);
        _keys[type] =
            (algo: algo, publicKey: kp.publicKey, secretKey: kp.secretKey);
        needsPublish = true;
        _log.info('Generated new $type signing keypair for $atSign');
      }

      // Publish before flipping _initialized: the outbound handshake gates
      // signing on isInitialised alone, so publishing later would emit cookies
      // for an unfetchable key instead of falling back to RSA.
      //
      // Only when something changed: the record is `public:` and commit-logged,
      // so republishing an identical value on every boot would push a no-op sync
      // delta to every enrolled client. The load path above read its keys out of
      // this very record, so an unchanged set is already correctly published.
      if (needsPublish) {
        await _publishPublicKeys(atSign, keyStore);
      }
      _initialized = true;
    } finally {
      _initFuture = null;
    }
  }

  /// Publish every held public key at [signingPublicKeysRecordKey] so peers can
  /// verify our handshake signatures.
  ///
  /// No [AtMetaData], unlike update-verb records: no `ttl`/`ttb` because these
  /// keypairs do not expire and a lapsed record would silently drop every peer
  /// to RSA; no `ttr` because peers re-fetch per handshake, so a regenerated
  /// keypair takes effect immediately.
  ///
  /// As a `public:` record this is commit-logged and syncs to enrolled clients —
  /// harmless for public keys; secret halves are `local:` (see
  /// [signing_key_constants]).
  Future<void> _publishPublicKeys(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    final record = buildSigningPublicKeysRecord(
        {for (final e in _keys.entries) e.key: e.value.publicKey});
    await keyStore.put(
        signingPublicKeysRecordKey(atSign), AtData()..data = record);
    _log.info('Published signing public keys for $atSign: '
        '${_keys.keys.join(", ")}');
  }

  /// Sign [challenge] with [type] and frame the cookie the verifier fetches at
  /// POL: `<type>:<base64 signature>`.
  ///
  /// Signs [challenge] verbatim, as the legacy RSA path does: it is already
  /// verifier-bound and names the accepted types, and verification is already
  /// scoped to this prover's published key, so the signed bytes need no further
  /// structure. Signing it verbatim is also what makes the in-band type advert
  /// tamper-evident — altering it in transit changes what was signed.
  Future<String> buildChallengeResponse(String challenge, String type) async {
    final held = _keys[type];
    if (!_initialized || held == null) {
      throw StateError('SigningKeyManager holds no $type key to sign with');
    }
    final String sigB64;
    try {
      sigB64 = await held.algo.signB64(challenge, held.secretKey);
    } catch (e) {
      // signB64's own FormatException/AtSigningException say nothing about
      // which type failed — this is the only remaining caller with `type` in
      // scope, so name it here rather than let a bare error surface.
      throw StateError('SigningKeyManager failed to sign with $type: $e');
    }
    return buildSignedCookie(type, sigB64);
  }

  /// Whether [secretKeyB64] and [publicKeyB64] are the two halves of one
  /// [algo] keypair — proven by a sign/verify round trip against a fresh
  /// nonce, not assumed from both being present.
  ///
  /// The two halves are read from independent keystore locations (this
  /// server's own `local:` secret, and the public half read back out of the
  /// `public:` record) and, without this check, paired on nothing but both
  /// being non-null. A mismatched pair — e.g. from a keystore restored from
  /// one snapshot and a record synced from another — would then load
  /// silently: nothing here looks "missing", so [needsPublish] never fires,
  /// and this server signs every subsequent handshake with a secret no
  /// peer's cached public key can verify. Permanently: there is no other
  /// path back to regeneration.
  ///
  /// Any failure is treated as "not a pair", not propagated. Signing/verifying
  /// via [Base64Signing] can throw for malformed material — bad base64, or
  /// at_chops' own validation of a corrupt-length secret key — and none of
  /// that is a reason to abort initialisation; it is exactly the case this
  /// check exists to catch and recover from by regenerating. Letting it
  /// escape would instead reach [AtSecondaryServerImpl.initializePqAuth]'s
  /// catch-all, which withdraws the published record entirely — dropping
  /// this atSign to legacy RSA fleet-wide, the opposite of self-healing.
  Future<bool> _pairMatches(AtSignatureAlgorithm algo, String secretKeyB64,
      String publicKeyB64) async {
    try {
      final nonce = Uuid().v4();
      final sig = await algo.signB64(nonce, secretKeyB64);
      return await algo.verifyB64(nonce, sig, publicKeyB64);
    } catch (_) {
      return false;
    }
  }

  /// Normalizes both ways an [AtKeyValueStore] impl can report a missing key —
  /// `null` or a not-found exception — to `null`.
  ///
  /// Anything else is logged at `severe`, because the caller reads `null` as "no
  /// key material" and regenerates: a silently swallowed transient store fault
  /// would rotate this server's signing identity and break verification for
  /// every peer holding the old published key.
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
