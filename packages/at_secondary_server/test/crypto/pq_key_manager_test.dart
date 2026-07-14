import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/crypto/pq_key_manager.dart';
import 'package:at_secondary/src/crypto/x_wing_cert.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  group('XWingCert', () {
    test('round-trips through JSON', () async {
      final kp = await XWingKeyPair.generate();
      final mlDsaKp = await MlDsa65KeyPair.generate();
      final validUntil =
          DateTime.now().toUtc().add(const Duration(days: 365));
      // Build a dummy cert (unsigned for this unit test).
      final cert = XWingCert(
        xwingPublicKey: kp.publicKeyBytes,
        validUntil: validUntil,
        signature: Uint8List(0),
        mlDsaPublicKey: mlDsaKp.publicKeyBytes,
      );
      final json = cert.toJson();
      final parsed = XWingCert.tryParse(json);
      expect(parsed, isNotNull);
      expect(parsed!.xwingPublicKey, equals(kp.publicKeyBytes));
      expect(parsed.mlDsaPublicKey, equals(mlDsaKp.publicKeyBytes));
      expect(parsed.validUntil.toUtc().toIso8601String(),
          equals(validUntil.toUtc().toIso8601String()));
    });

    test('tryParse returns null for malformed input', () {
      expect(XWingCert.tryParse('not-json'), isNull);
      expect(XWingCert.tryParse('{"bad":"data"}'), isNull);
    });

    test('tbsBytes is xwingPubKey || validUntil_utf8 || mlDsaPubKey',
        () async {
      final kp = await XWingKeyPair.generate();
      final mlDsaKp = await MlDsa65KeyPair.generate();
      final validUntil = DateTime(2026, 1, 1, 0, 0, 0, 0, 0).toUtc();
      final cert = XWingCert(
        xwingPublicKey: kp.publicKeyBytes,
        validUntil: validUntil,
        signature: Uint8List(0),
        mlDsaPublicKey: mlDsaKp.publicKeyBytes,
      );
      final expected = Uint8List.fromList([
        ...kp.publicKeyBytes,
        ...utf8.encode(validUntil.toIso8601String()),
        ...mlDsaKp.publicKeyBytes,
      ]);
      expect(cert.tbsBytes, equals(expected));
    });

    test('valid cert passes verify()', () async {
      final mlDsaKp = await MlDsa65KeyPair.generate();
      final xwingKp = await XWingKeyPair.generate();
      final validUntil = DateTime.now().toUtc().add(const Duration(days: 30));

      final draft = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: Uint8List(0),
          mlDsaPublicKey: mlDsaKp.publicKeyBytes);
      final sig = await AtPqc.mlDsa65
          .signBytes(draft.tbsBytes, secretKey: mlDsaKp.privateKeyBytes);
      final cert = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: sig,
          mlDsaPublicKey: mlDsaKp.publicKeyBytes);

      expect(await cert.verify(), isTrue);
    });

    test('expired cert fails verify()', () async {
      final mlDsaKp = await MlDsa65KeyPair.generate();
      final xwingKp = await XWingKeyPair.generate();
      final validUntil =
          DateTime.now().toUtc().subtract(const Duration(hours: 1));

      final draft = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: Uint8List(0),
          mlDsaPublicKey: mlDsaKp.publicKeyBytes);
      final sig = await AtPqc.mlDsa65
          .signBytes(draft.tbsBytes, secretKey: mlDsaKp.privateKeyBytes);
      final cert = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: sig,
          mlDsaPublicKey: mlDsaKp.publicKeyBytes);

      expect(await cert.verify(), isFalse);
    });

    test('cert whose embedded ML-DSA key does not match the signer fails verify()',
        () async {
      final signerKp = await MlDsa65KeyPair.generate();
      final wrongKp = await MlDsa65KeyPair.generate();
      final xwingKp = await XWingKeyPair.generate();
      final validUntil = DateTime.now().toUtc().add(const Duration(days: 30));

      // Signed with signerKp, but the cert claims a different embedded
      // ML-DSA public key — signature verification against the embedded key
      // must fail.
      final draft = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: Uint8List(0),
          mlDsaPublicKey: wrongKp.publicKeyBytes);
      final sig = await AtPqc.mlDsa65
          .signBytes(draft.tbsBytes, secretKey: signerKp.privateKeyBytes);
      final cert = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: sig,
          mlDsaPublicKey: wrongKp.publicKeyBytes);

      expect(await cert.verify(), isFalse);
    });
  });

  group('PqKeyManager', () {
    late HiveKeyStoreFixture fixture;
    late AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
    const atSign = '@testserver';

    setUp(() async {
      fixture = HiveKeyStoreFixture('test/hive_pq_key_manager');
      keyStore = await fixture.open(atSign.toAtsign());
    });

    tearDown(() async => await fixture.dispose());

    group('init()', () {
      test('missing public companion key triggers regeneration, not a throw',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        final xwingPubBefore = mgr.xwingPublicKey;

        // Simulate the public X-Wing key record being deleted (owner-deletable)
        // while the secret key survives.
        await keyStore.remove(pqXwingPublicKeyName(atSign));

        final mgr2 = PqKeyManager();
        await expectLater(mgr2.init(atSign, keyStore), completes);

        // A fresh keypair must have been generated — not a crash.
        expect(mgr2.xwingPublicKey, isNot(equals(xwingPubBefore)));
      });

      test('isInitialised is false before init() and true after', () async {
        final mgr = PqKeyManager();
        expect(mgr.isInitialised, isFalse);
        await mgr.init(atSign, keyStore);
        expect(mgr.isInitialised, isTrue);
      });
    });

    group('publishKeys()', () {
      test('republishes when the existing cert binds a stale X-Wing public key',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);
        final certBefore =
            (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;
        expect(certBefore, isNotNull);

        // Simulate a keypair regeneration (e.g. after partial keystore loss)
        // while a still-valid cert for the OLD public key remains published.
        await mgr.rotateCert(atSign, keyStore);
        // rotateCert already republishes, so force the stale scenario directly:
        // put back the original (now-stale) cert as the "current" cert.
        await keyStore.put(pqXwingCertRecordName(atSign), AtData()..data = certBefore);

        await mgr.publishKeys(atSign, keyStore);

        final certAfter =
            (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;
        expect(certAfter, isNot(equals(certBefore)),
            reason: 'A cert bound to a key the manager no longer holds '
                'must be republished, not treated as still valid');
        final parsed = XWingCert.tryParse(certAfter!);
        expect(parsed!.xwingPublicKey, equals(mgr.xwingPublicKey));
      });

      test('publishKeys() removes prev cert and prev secret after expiry',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);
        await mgr.rotateCert(atSign, keyStore);
        expect(await keyStore.exists(pqXwingSecretKeyPrevName(atSign)), isTrue);

        // Force the prev cert to look expired.
        final expiredCertJson = await buildSignedPeerCertJson(
            validUntil:
                DateTime.now().toUtc().subtract(const Duration(days: 1)));
        await keyStore.put(
            pqXwingCertPrevName(atSign), AtData()..data = expiredCertJson);

        await mgr.publishKeys(atSign, keyStore);

        expect(await keyStore.exists(pqXwingCertPrevName(atSign)), isFalse,
            reason: 'Expired prev cert must be deleted');
        expect(await keyStore.exists(pqXwingSecretKeyPrevName(atSign)), isFalse,
            reason: 'Expired prev secret key must be deleted alongside '
                'the expired prev cert');
        expect(await keyStore.exists(pqXwingCertRecordName(atSign)), isTrue,
            reason: 'Current cert must be published/generated');
      });

      test('publishKeys() retains a still-valid prev cert', () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);

        final recentCertJson = await buildSignedPeerCertJson(
            validUntil: DateTime.now().toUtc().add(const Duration(days: 5)));
        await keyStore.put(
            pqXwingCertPrevName(atSign), AtData()..data = recentCertJson);

        await mgr.publishKeys(atSign, keyStore);

        expect(await keyStore.exists(pqXwingCertPrevName(atSign)), isTrue,
            reason: 'A still-valid prev cert must NOT be deleted');
        expect(await keyStore.exists(pqXwingCertRecordName(atSign)), isTrue,
            reason: 'Current cert must be published/generated');
      });

      test('inside renewal headroom rotates instead of no-op', () async {
        final mgr = PqKeyManager(
            certExpiryDays: 90, certRenewalHeadroomDays: 30);
        await mgr.init(atSign, keyStore);
        // First publish issues a 90-day cert — outside headroom.
        await mgr.publishKeys(atSign, keyStore);
        final certBefore = (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;
        final xwingPubBefore = mgr.xwingPublicKey;

        // Force the current cert to look like it's inside the renewal
        // headroom (10 days left, headroom is 30).
        final soonCert = await mgr.buildCert(
            validUntil: DateTime.now().toUtc().add(const Duration(days: 10)));
        await keyStore.put(pqXwingCertRecordName(atSign), AtData()..data = soonCert.toJson());

        await mgr.publishKeys(atSign, keyStore);

        final certAfter = (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;
        expect(certAfter, isNot(equals(certBefore)));
        expect(mgr.xwingPublicKey, isNot(equals(xwingPubBefore)),
            reason: 'Inside headroom must rotate the keypair, not just '
                'republish a fresh cert over the same key');
        final prevCert = (await keyStore.get(pqXwingCertPrevName(atSign)))?.data;
        expect(prevCert, isNotNull);
      });

      test(
          'headroom >= expiry is clamped to 0 instead of rotating on every boot',
          () async {
        // certRenewalHeadroomDays (10) >= certExpiryDays (5): without the
        // clamp, effectiveHeadroomDays would equal certRenewalHeadroomDays
        // and renewAt would always be beyond validUntil, forcing a rotation
        // on every publishKeys() call.
        final mgr =
            PqKeyManager(certExpiryDays: 5, certRenewalHeadroomDays: 10);
        await mgr.init(atSign, keyStore);
        final xwingPubBefore = mgr.xwingPublicKey;

        final cert = await mgr.buildCert(
            validUntil: DateTime.now().toUtc().add(const Duration(days: 5)));
        await keyStore.put(
            pqXwingCertRecordName(atSign), AtData()..data = cert.toJson());

        await mgr.publishKeys(atSign, keyStore);

        final certAfter =
            (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;
        expect(certAfter, equals(cert.toJson()),
            reason: 'With headroom clamped to 0, a cert still within its '
                'full validity window must not be rotated');
        expect(mgr.xwingPublicKey, equals(xwingPubBefore));
      });
    });

    group('rotateCert()', () {
      test('rotateCert() promotes current cert to prev and publishes new cert',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);

        final certBefore =
            (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;
        expect(certBefore, isNotNull);

        await mgr.rotateCert(atSign, keyStore);

        final prevCert =
            (await keyStore.get(pqXwingCertPrevName(atSign)))?.data;
        final newCert = (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;

        expect(prevCert, equals(certBefore));
        expect(newCert, isNotNull);
        expect(newCert, isNot(equals(certBefore)));
      });

      test('data encrypted under prev key is still decapsulable after rotation',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);

        final kemResult = await AtPqc.xWing.encapsulate(mgr.xwingPublicKey);

        final oldPub = mgr.xwingPublicKey;
        await mgr.rotateCert(atSign, keyStore);

        final prevCertRaw = (await keyStore.get(pqXwingCertPrevName(atSign)))?.data;
        expect(prevCertRaw, isNotNull);
        final prevCert = XWingCert.tryParse(prevCertRaw!);
        expect(prevCert!.xwingPublicKey, equals(oldPub),
            reason: 'Prev cert public key must match the key before rotation');

        final persistedPrevSecret =
            (await keyStore.get(pqXwingSecretKeyPrevName(atSign)))?.data;
        expect(persistedPrevSecret, isNotNull,
            reason: 'Manager must retain prev secret key after rotation');

        final recovered = await AtPqc.xWing.decapsulate(
            base64.decode(persistedPrevSecret!), kemResult.ciphertext);
        expect(recovered, equals(kemResult.sharedSecret));
      });

      test(
          'decapsWithFallback recovers a peer that encapsulated to the prev cert',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);

        // A peer encapsulates against the pre-rotation public key (as if it
        // cached the cert across the rotation).
        final kemResult = await AtPqc.xWing.encapsulate(mgr.xwingPublicKey);

        await mgr.rotateCert(atSign, keyStore);

        final result = await mgr.decapsWithFallback(kemResult.ciphertext);
        expect(result.prev, equals(kemResult.sharedSecret));
        expect(result.current, isNot(equals(kemResult.sharedSecret)));
      });

      test('prev secret key survives a reload (restart) after rotation',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);

        final kemResult = await AtPqc.xWing.encapsulate(mgr.xwingPublicKey);
        await mgr.rotateCert(atSign, keyStore);

        // Simulate a restart: a fresh manager instance reloads from the
        // keystore instead of retaining in-memory state.
        final reloaded = PqKeyManager();
        await reloaded.init(atSign, keyStore);

        expect(await keyStore.exists(pqXwingSecretKeyPrevName(atSign)), isTrue,
            reason: 'Prev secret key must be persisted and reloaded, not '
                'lost on restart');
        final result = await reloaded.decapsWithFallback(kemResult.ciphertext);
        expect(result.prev, equals(kemResult.sharedSecret));
      });
    });

    group('cert expiry config', () {
      test('buildCert() honours the certExpiryDays ctor param', () async {
        final mgr = PqKeyManager(certExpiryDays: 7);
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);

        final certRaw = (await keyStore.get(pqXwingCertRecordName(atSign)))?.data;
        final cert = XWingCert.tryParse(certRaw!);

        final expected = DateTime.now().toUtc().add(const Duration(days: 7));
        expect(cert!.validUntil.difference(expected).inMinutes.abs(),
            lessThan(5),
            reason: 'validUntil must reflect the ctor-supplied expiry, not '
                'the default');
      });
    });

    group('record namespacing', () {
      test('all PQ records except the cert are stored under local:',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishKeys(atSign, keyStore);
        await mgr.rotateCert(atSign, keyStore);

        for (final name in [
          pqSigningSecretKeyName(atSign),
          pqSigningPublicKeyName(atSign),
          pqXwingSecretKeyName(atSign),
          pqXwingPublicKeyName(atSign),
          pqXwingSecretKeyPrevName(atSign),
          pqXwingCertPrevName(atSign),
        ]) {
          expect(name, startsWith('local:'), reason: name);
          expect(await keyStore.exists(name), isTrue, reason: name);
        }
        expect(pqXwingCertRecordName(atSign), startsWith('public:'));
        expect(await keyStore.exists(pqXwingCertRecordName(atSign)), isTrue);
      });
    });
  });
}
