import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pol_signing_algos.dart';
import 'package:at_secondary/src/crypto/signing_key_constants.dart';
import 'package:at_secondary/src/crypto/signing_key_manager.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// Covers [SigningKeyManager.init]'s load-vs-regenerate decision, in
/// particular that a stored secret and a published public key are never
/// paired on nothing but both being non-null.
///
/// The two halves come from independent keystore locations — this server's
/// own `local:` secret and the public half read back out of the `public:`
/// record — so they can genuinely disagree, e.g. a keystore restored from one
/// snapshot alongside a record synced from another. Loading a mismatched pair
/// silently would be permanent: nothing about it looks "missing", so the
/// record is never republished, and this server signs every subsequent
/// handshake with a secret no peer's cached public key can verify.
void main() {
  final atSign = alice.toString();

  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  test('loads a genuinely matching stored secret and published public key',
      () async {
    final algo = negotiableSigningAlgos[polAlgoMlDsa65]!;
    final kp = await algo.generateKeyPairB64();
    await keyValueStore.put(signingSecretKeyName(polAlgoMlDsa65, atSign),
        AtData()..data = kp.secretKey);
    await keyValueStore.put(
        signingPublicKeysRecordKey(atSign),
        AtData()
          ..data = buildSigningPublicKeysRecord({polAlgoMlDsa65: kp.publicKey}));

    final manager = SigningKeyManager();
    await manager.init(atSign, keyValueStore);

    expect(manager.publicKeyFor(polAlgoMlDsa65), kp.publicKey,
        reason: 'a matching pair must load as-is, not regenerate');
  });

  test(
      'regenerates rather than loading when the stored secret does not '
      'match the published public key', () async {
    final algo = negotiableSigningAlgos[polAlgoMlDsa65]!;
    final storedKp = await algo.generateKeyPairB64();
    final publishedKp = await algo.generateKeyPairB64(); // a different keypair
    await keyValueStore.put(signingSecretKeyName(polAlgoMlDsa65, atSign),
        AtData()..data = storedKp.secretKey);
    await keyValueStore.put(
        signingPublicKeysRecordKey(atSign),
        AtData()
          ..data = buildSigningPublicKeysRecord(
              {polAlgoMlDsa65: publishedKp.publicKey}));

    final manager = SigningKeyManager();
    await manager.init(atSign, keyValueStore);

    final published = manager.publicKeyFor(polAlgoMlDsa65);
    expect(published, isNot(equals(publishedKp.publicKey)),
        reason: 'the mismatched pair must not be loaded');
    expect(published, isNot(equals(storedKp.publicKey)),
        reason: 'a fresh keypair must be generated, not the stored half '
            'paired with itself');

    // The republished record must actually verify against what we now sign
    // with — i.e. this server can no longer be left signing with a secret no
    // peer's cached public key can check.
    final rawRecord =
        (await keyValueStore.get(signingPublicKeysRecordKey(atSign)))?.data;
    expect(signingPublicKeyForType(rawRecord!, polAlgoMlDsa65), published);
  });

  test(
      'regenerates, rather than throwing, when the stored secret is '
      'corrupt-length', () async {
    // The pairing round-trip goes through the Base64Signing extension, and at_chops throws
    // AtSigningException for a wrong-length secret key. That must not escape
    // init — it is exactly the case this check exists to catch and recover
    // from, not a reason to abort initialisation (which would otherwise reach
    // AtSecondaryServerImpl.initializePqAuth's catch-all and withdraw the
    // published record, dropping this atSign to legacy RSA fleet-wide).
    final algo = negotiableSigningAlgos[polAlgoMlDsa65]!;
    final publishedKp = await algo.generateKeyPairB64();
    await keyValueStore.put(signingSecretKeyName(polAlgoMlDsa65, atSign),
        AtData()..data = 'not-even-base64!!');
    await keyValueStore.put(
        signingPublicKeysRecordKey(atSign),
        AtData()
          ..data = buildSigningPublicKeysRecord(
              {polAlgoMlDsa65: publishedKp.publicKey}));

    final manager = SigningKeyManager();
    await expectLater(manager.init(atSign, keyValueStore), completes);
    expect(manager.isInitialised, isTrue);
    expect(manager.publicKeyFor(polAlgoMlDsa65), isNot(equals(publishedKp.publicKey)));
  });
}
