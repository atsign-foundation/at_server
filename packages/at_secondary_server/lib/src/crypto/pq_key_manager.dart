import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/crypto/x_wing_cert.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';

/// Manages PQ keypairs for inter-server authentication.
///
/// Two-tier hierarchy:
///   ML-DSA-65 root key  → long-lived trust anchor, signs X-Wing certs
///   X-Wing operational  → used for KEM-based proof-of-possession in FROM/POL
class PqKeyManager {
  static final PqKeyManager instance = PqKeyManager();

  /// Own-cert renewal thresholds. Peer-cert verification ([XWingCert.verify])
  /// stays strict — these only decide when *this* server rotates its own
  /// cert, never whether a peer's cert is accepted.
  final int certExpiryDays;
  final int certRenewalHeadroomDays;

  PqKeyManager({int? certExpiryDays, int? certRenewalHeadroomDays})
      : certExpiryDays =
            certExpiryDays ?? AtSecondaryConfig.xwingCertExpiryInDays,
        certRenewalHeadroomDays =
            certRenewalHeadroomDays ?? AtSecondaryConfig.certRenewalHeadroomDays;

  static final _log = AtSignLogger('PqKeyManager');

  late Uint8List _mlDsaSecretKey;
  late Uint8List _mlDsaPublicKey;
  late Uint8List _xwingSecretKey;
  late Uint8List _xwingPublicKey;
  Uint8List? _xwingPrevSecretKey;

  Uint8List get mlDsaPublicKey => _mlDsaPublicKey;
  Uint8List get xwingPublicKey => _xwingPublicKey;

  bool _initialized = false;
  Future<void>? _initFuture;

  /// Whether [init] has completed successfully. Callers on the PQ handshake
  /// path must check this before invoking [decapsWithFallback] — otherwise a
  /// failed/never-run init surfaces as an uncaught [StateError] deep in the
  /// handshake instead of a clean fallback to the legacy path.
  bool get isInitialised => _initialized;

  /// Load existing PQ keypairs from [keyStore] or generate fresh ones.
  ///
  /// Concurrent callers share a single in-flight attempt: the started
  /// [Future] is cached (rather than short-circuited by a boolean flag) so a
  /// second caller awaits the same result instead of returning immediately
  /// while the first call is still in progress.
  Future<void> init(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit(atSign, keyStore);
  }

  Future<void> _doInit(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    try {
      final mlDsaSecKeyName = pqSigningSecretKeyName(atSign);
      final mlDsaPubKeyName = pqSigningPublicKeyName(atSign);
      final xwingSecKeyName = pqXwingSecretKeyName(atSign);
      final xwingPubKeyName = pqXwingPublicKeyName(atSign);
      final xwingPrevSecKeyName = pqXwingSecretKeyPrevName(atSign);

      final existingMlDsaSec = await _getOrNull(keyStore, mlDsaSecKeyName);
      final existingMlDsaPub = await _getOrNull(keyStore, mlDsaPubKeyName);
      final existingXwingSec = await _getOrNull(keyStore, xwingSecKeyName);
      final existingXwingPub = await _getOrNull(keyStore, xwingPubKeyName);

      if (existingMlDsaSec != null &&
          existingMlDsaPub != null &&
          existingXwingSec != null &&
          existingXwingPub != null) {
        _mlDsaSecretKey = base64.decode(existingMlDsaSec);
        _mlDsaPublicKey = base64.decode(existingMlDsaPub);
        _xwingSecretKey = base64.decode(existingXwingSec);
        _xwingPublicKey = base64.decode(existingXwingPub);
        final existingXwingPrev =
            await _getOrNull(keyStore, xwingPrevSecKeyName);
        if (existingXwingPrev != null) {
          _xwingPrevSecretKey = base64.decode(existingXwingPrev);
        }
        _log.info('Loaded existing PQ keypairs for $atSign');
      } else {
        if (existingMlDsaSec != null ||
            existingMlDsaPub != null ||
            existingXwingSec != null ||
            existingXwingPub != null) {
          _log.warning('Partial/missing PQ key material for $atSign — '
              'regenerating keypairs');
        }
        await _generateAndStore(atSign, keyStore);
        // A fresh keypair invalidates any retained grace-period fallback.
        await keyStore.remove(pqXwingCertPrevName(atSign));
        await keyStore.remove(xwingPrevSecKeyName);
        _xwingPrevSecretKey = null;
        _log.info('Generated new PQ keypairs for $atSign');
      }

      _initialized = true;
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _generateAndStore(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    final mlDsaKp = await MlDsa65KeyPair.generate();
    final xwingKp = await XWingKeyPair.generate();

    _mlDsaSecretKey = mlDsaKp.privateKeyBytes;
    _mlDsaPublicKey = mlDsaKp.publicKeyBytes;
    _xwingSecretKey = xwingKp.privateKeyBytes;
    _xwingPublicKey = xwingKp.publicKeyBytes;

    await keyStore.put(pqSigningSecretKeyName(atSign),
        AtData()..data = base64.encode(_mlDsaSecretKey));
    await keyStore.put(pqSigningPublicKeyName(atSign),
        AtData()..data = base64.encode(_mlDsaPublicKey));
    await keyStore.put(pqXwingSecretKeyName(atSign),
        AtData()..data = base64.encode(_xwingSecretKey));
    await keyStore.put(pqXwingPublicKeyName(atSign),
        AtData()..data = base64.encode(_xwingPublicKey));
  }

  /// Ensure a valid, current X-Wing cert is published, rotating if renewal is
  /// due. Single entry point for both first-publish and ongoing renewal:
  ///
  /// 1. GC the prev cert/secret if the prev cert is unparseable or expired.
  /// 2. Current cert parses, its embedded key matches ours, and it's valid
  ///    beyond the renewal headroom → nothing to do.
  /// 3. Missing/corrupt current cert, or its embedded key no longer matches
  ///    ours → fresh-publish over the current keypair; prev slots untouched.
  /// 4. Current cert valid but inside the renewal headroom → [rotateCert].
  Future<void> publishKeys(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    _assertInitialized();
    final certName = pqXwingCertRecordName(atSign);
    final certPrevName = pqXwingCertPrevName(atSign);
    final secretPrevName = pqXwingSecretKeyPrevName(atSign);

    final prevCertRaw = await _getOrNull(keyStore, certPrevName);
    if (prevCertRaw != null) {
      final parsedPrev = XWingCert.tryParse(prevCertRaw);
      if (parsedPrev == null ||
          parsedPrev.validUntil.isBefore(DateTime.now().toUtc())) {
        await keyStore.remove(certPrevName);
        await keyStore.remove(secretPrevName);
        _xwingPrevSecretKey = null;
        _log.info('Cleaned up expired/unparseable prev X-Wing cert for $atSign');
      }
    }

    final currentCertRaw = await _getOrNull(keyStore, certName);
    if (currentCertRaw != null) {
      final currentCert = XWingCert.tryParse(currentCertRaw);
      if (currentCert != null &&
          _bytesEqual(currentCert.xwingPublicKey, _xwingPublicKey)) {
        final renewAt = DateTime.now()
            .toUtc()
            .add(Duration(days: _effectiveHeadroomDays));
        if (currentCert.validUntil.isAfter(renewAt)) {
          _log.info('Existing X-Wing cert for $atSign is still valid');
          return;
        }
        await rotateCert(atSign, keyStore);
        return;
      }
    }

    final cert = await buildCert();
    await keyStore.put(certName, AtData()..data = cert.toJson());
    _log.info('Published fresh X-Wing cert for $atSign');
  }

  /// Rotate the server's X-Wing operational keypair: the current cert and
  /// secret key move to the prev slots (retained for grace-period
  /// decapsulation via [decapsWithFallback]), and a fresh keypair + cert
  /// replace them.
  Future<void> rotateCert(String atSign,
      AtKeyValueStore<String, AtData, AtMetaData?> keyStore) async {
    _assertInitialized();
    final certName = pqXwingCertRecordName(atSign);
    final certPrevName = pqXwingCertPrevName(atSign);
    final secretPrevName = pqXwingSecretKeyPrevName(atSign);

    final currentCert = await _getOrNull(keyStore, certName);
    if (currentCert != null) {
      await keyStore.put(certPrevName, AtData()..data = currentCert);
    }

    _xwingPrevSecretKey = _xwingSecretKey;
    await keyStore.put(secretPrevName,
        AtData()..data = base64.encode(_xwingPrevSecretKey!));

    final newKp = await XWingKeyPair.generate();
    _xwingSecretKey = newKp.privateKeyBytes;
    _xwingPublicKey = newKp.publicKeyBytes;

    await keyStore.put(pqXwingSecretKeyName(atSign),
        AtData()..data = base64.encode(_xwingSecretKey));
    await keyStore.put(pqXwingPublicKeyName(atSign),
        AtData()..data = base64.encode(_xwingPublicKey));

    final cert = await buildCert();
    await keyStore.put(certName, AtData()..data = cert.toJson());
    _log.info('Rotated X-Wing cert for $atSign');
  }

  /// Build and sign a fresh [XWingCert] over the current keypair. Public so
  /// tests can build certs identically to production.
  Future<XWingCert> buildCert({DateTime? validUntil}) async {
    _assertInitialized();
    final effectiveValidUntil = validUntil ??
        DateTime.now().toUtc().add(Duration(days: certExpiryDays));
    final tmp = XWingCert(
      xwingPublicKey: _xwingPublicKey,
      validUntil: effectiveValidUntil,
      signature: Uint8List(0),
      mlDsaPublicKey: _mlDsaPublicKey,
    );
    final sig = await AtPqc.mlDsa65
        .signBytes(tmp.tbsBytes, secretKey: _mlDsaSecretKey);
    return XWingCert(
        xwingPublicKey: _xwingPublicKey,
        validUntil: effectiveValidUntil,
        signature: sig,
        mlDsaPublicKey: _mlDsaPublicKey);
  }

  /// Decapsulate [ciphertext] against the current key and, if a rotation
  /// grace-period key is retained, the previous key too.
  ///
  /// X-Wing implicit rejection never throws on a mismatched key — it silently
  /// returns a different shared secret — so a peer that encapsulated to the
  /// previous cert (still valid during the rotation grace window) cannot be
  /// distinguished here. Both candidate secrets are returned; the caller
  /// derives a confirmation tag from each and lets the peer's independently
  /// derived tag pick the winner.
  Future<({Uint8List current, Uint8List? prev})> decapsWithFallback(
      Uint8List ciphertext) async {
    _assertInitialized();
    final current = await AtPqc.xWing.decapsulate(_xwingSecretKey, ciphertext);
    final prevKey = _xwingPrevSecretKey;
    if (prevKey == null) return (current: current, prev: null);
    final prev = await AtPqc.xWing.decapsulate(prevKey, ciphertext);
    return (current: current, prev: prev);
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  /// `certExpiryDays > certRenewalHeadroomDays` guarantees a positive window
  /// during which the cert is valid but outside the headroom. When the
  /// headroom would consume the entire lifetime, disable it (0) rather than
  /// rotate on every boot.
  int get _effectiveHeadroomDays {
    if (certExpiryDays > certRenewalHeadroomDays) {
      return certRenewalHeadroomDays;
    }
    _log.severe('certRenewalHeadroomDays ($certRenewalHeadroomDays) >= '
        'certExpiryDays ($certExpiryDays) — disabling renewal headroom to '
        'avoid rotating on every boot');
    return 0;
  }

  void _assertInitialized() {
    if (!_initialized) throw StateError('PqKeyManager not initialised');
  }

  /// Constant-time comparison: always scans the shorter length and folds
  /// the length mismatch into the result, so timing doesn't leak how many
  /// leading bytes of a public key matched.
  bool _bytesEqual(Uint8List a, Uint8List b) {
    var diff = a.length ^ b.length;
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// `get` may return `null` for a missing key or throw a backend-specific
  /// not-found exception depending on the concrete [AtKeyValueStore] impl —
  /// normalize both cases to `null`.
  Future<String?> _getOrNull(
      AtKeyValueStore<String, AtData, AtMetaData?> ks, String key) async {
    try {
      return (await ks.get(key))?.data;
    } catch (e) {
      _log.finer('Error retrieving key $key: ${e.toString()}');
      return null;
    }
  }
}

/// Derive the key-confirmation tag used in FROM/POL handshakes.
///
/// Both sides derive this from the same raw shared secret [sharedSecret] and
/// handshake context [sessionIdWithAtSign]; the tag is stored/compared, and
/// [sharedSecret] is never persisted or transmitted. `HkdfSha256.deriveKey`
/// is itself synchronous, so this wraps it without an unnecessary `Future`.
Uint8List deriveConfirmationTag(
    Uint8List sharedSecret, String sessionIdWithAtSign) {
  return HkdfSha256.deriveKey(sharedSecret,
      info: Uint8List.fromList(utf8.encode(sessionIdWithAtSign)), length: 32);
}
