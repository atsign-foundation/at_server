import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
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
      // Build a dummy xwingCert (unsigned for this unit test).
      final xwingCert = XWingCert(
        xwingPublicKey: kp.publicKeyBytes,
        validUntil: validUntil,
        signature: Uint8List(0),
        mlDsaPublicKey: mlDsaKp.publicKeyBytes,
      );
      final json = xwingCert.toJson();
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
      final xwingCert = XWingCert(
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
      expect(xwingCert.tbsBytes, equals(expected));
    });

    test('valid xwingCert passes verify()', () async {
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
      final xwingCert = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: sig,
          mlDsaPublicKey: mlDsaKp.publicKeyBytes);

      expect(await xwingCert.verify(), isTrue);
    });

    test('expired xwingCert fails verify()', () async {
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
      final xwingCert = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: sig,
          mlDsaPublicKey: mlDsaKp.publicKeyBytes);

      expect(await xwingCert.verify(), isFalse);
    });

    test('xwingCert whose embedded ML-DSA key does not match the signer fails verify()',
        () async {
      final signerKp = await MlDsa65KeyPair.generate();
      final wrongKp = await MlDsa65KeyPair.generate();
      final xwingKp = await XWingKeyPair.generate();
      final validUntil = DateTime.now().toUtc().add(const Duration(days: 30));

      // Signed with signerKp, but the xwingCert claims a different embedded
      // ML-DSA public key — signature verification against the embedded key
      // must fail.
      final draft = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: Uint8List(0),
          mlDsaPublicKey: wrongKp.publicKeyBytes);
      final sig = await AtPqc.mlDsa65
          .signBytes(draft.tbsBytes, secretKey: signerKp.privateKeyBytes);
      final xwingCert = XWingCert(
          xwingPublicKey: xwingKp.publicKeyBytes,
          validUntil: validUntil,
          signature: sig,
          mlDsaPublicKey: wrongKp.publicKeyBytes);

      expect(await xwingCert.verify(), isFalse);
    });
  });

  group('PqKeyManager', () {
    late AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
    final atSign = alice.toString();

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      keyStore = keyValueStore;
    });

    tearDown(() async => await verbTestsTearDown());

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

    group('publishCert()', () {
      test('republishes when the existing xwingCert binds a stale X-Wing public key',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishCert(atSign, keyStore);
        final xwingCertBefore =
            (await keyStore.get(pqXwingCertName(atSign)))?.data;
        expect(xwingCertBefore, isNotNull);

        // Simulate a keypair regeneration (e.g. after partial keystore loss)
        // while a still-valid xwingCert for the OLD public key remains published.
        await mgr.rotateCert(atSign, keyStore);
        // rotateCert already republishes, so force the stale scenario directly:
        // put back the original (now-stale) xwingCert as the "current" xwingCert.
        await keyStore.put(pqXwingCertName(atSign), AtData()..data = xwingCertBefore);

        await mgr.publishCert(atSign, keyStore);

        final xwingCertAfter =
            (await keyStore.get(pqXwingCertName(atSign)))?.data;
        expect(xwingCertAfter, isNot(equals(xwingCertBefore)),
            reason: 'A xwingCert bound to a key the manager no longer holds '
                'must be republished, not treated as still valid');
        final parsed = XWingCert.tryParse(xwingCertAfter!);
        expect(parsed!.xwingPublicKey, equals(mgr.xwingPublicKey));
      });

      test('publishCert() removes prev xwingCert and prev secret after expiry',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishCert(atSign, keyStore);
        await mgr.rotateCert(atSign, keyStore);
        expect(await keyStore.exists(pqXwingSecretKeyPrevName(atSign)), isTrue);

        // Force the prev xwingCert to look expired.
        final expiredXwingCertJson = await buildSignedPeerCertJson(
            validUntil:
                DateTime.now().toUtc().subtract(const Duration(days: 1)));
        await keyStore.put(
            pqXwingCertPrevName(atSign), AtData()..data = expiredXwingCertJson);

        await mgr.publishCert(atSign, keyStore);

        expect(await keyStore.exists(pqXwingCertPrevName(atSign)), isFalse,
            reason: 'Expired prev xwingCert must be deleted');
        expect(await keyStore.exists(pqXwingSecretKeyPrevName(atSign)), isFalse,
            reason: 'Expired prev secret key must be deleted alongside '
                'the expired prev xwingCert');
        expect(await keyStore.exists(pqXwingCertName(atSign)), isTrue,
            reason: 'Current xwingCert must be published/generated');
      });

      test('publishCert() retains a still-valid prev xwingCert', () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);

        final recentXwingCertJson = await buildSignedPeerCertJson(
            validUntil: DateTime.now().toUtc().add(const Duration(days: 5)));
        await keyStore.put(
            pqXwingCertPrevName(atSign), AtData()..data = recentXwingCertJson);

        await mgr.publishCert(atSign, keyStore);

        expect(await keyStore.exists(pqXwingCertPrevName(atSign)), isTrue,
            reason: 'A still-valid prev xwingCert must NOT be deleted');
        expect(await keyStore.exists(pqXwingCertName(atSign)), isTrue,
            reason: 'Current xwingCert must be published/generated');
      });

      test('inside renewal headroom rotates instead of no-op', () async {
        final mgr = PqKeyManager(
            xwingCertExpiryDays: 90, xwingCertRenewalHeadroomDays: 30);
        await mgr.init(atSign, keyStore);
        // First publish issues a 90-day xwingCert — outside headroom.
        await mgr.publishCert(atSign, keyStore);
        final xwingCertBefore = (await keyStore.get(pqXwingCertName(atSign)))?.data;
        final xwingPubBefore = mgr.xwingPublicKey;

        // Force the current xwingCert to look like it's inside the renewal
        // headroom (10 days left, headroom is 30).
        final soonXwingCert = await mgr.buildCert(
            validUntil: DateTime.now().toUtc().add(const Duration(days: 10)));
        await keyStore.put(pqXwingCertName(atSign), AtData()..data = soonXwingCert.toJson());

        await mgr.publishCert(atSign, keyStore);

        final xwingCertAfter = (await keyStore.get(pqXwingCertName(atSign)))?.data;
        expect(xwingCertAfter, isNot(equals(xwingCertBefore)));
        expect(mgr.xwingPublicKey, isNot(equals(xwingPubBefore)),
            reason: 'Inside headroom must rotate the keypair, not just '
                'republish a fresh xwingCert over the same key');
        final prevXwingCert = (await keyStore.get(pqXwingCertPrevName(atSign)))?.data;
        expect(prevXwingCert, isNotNull);
      });

      test(
          'headroom >= expiry is clamped to 0 instead of rotating on every boot',
          () async {
        // xwingCertRenewalHeadroomDays (10) >= xwingCertExpiryDays (5): without the
        // clamp, effectiveHeadroomDays would equal xwingCertRenewalHeadroomDays
        // and renewAt would always be beyond validUntil, forcing a rotation
        // on every publishCert() call.
        final mgr =
            PqKeyManager(xwingCertExpiryDays: 5, xwingCertRenewalHeadroomDays: 10);
        await mgr.init(atSign, keyStore);
        final xwingPubBefore = mgr.xwingPublicKey;

        final xwingCert = await mgr.buildCert(
            validUntil: DateTime.now().toUtc().add(const Duration(days: 5)));
        await keyStore.put(
            pqXwingCertName(atSign), AtData()..data = xwingCert.toJson());

        await mgr.publishCert(atSign, keyStore);

        final xwingCertAfter =
            (await keyStore.get(pqXwingCertName(atSign)))?.data;
        expect(xwingCertAfter, equals(xwingCert.toJson()),
            reason: 'With headroom clamped to 0, a xwingCert still within its '
                'full validity window must not be rotated');
        expect(mgr.xwingPublicKey, equals(xwingPubBefore));
      });
    });

    group('rotateCert()', () {
      test('rotateCert() promotes current xwingCert to prev and publishes new xwingCert',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishCert(atSign, keyStore);

        final xwingCertBefore =
            (await keyStore.get(pqXwingCertName(atSign)))?.data;
        expect(xwingCertBefore, isNotNull);

        await mgr.rotateCert(atSign, keyStore);

        final prevXwingCert =
            (await keyStore.get(pqXwingCertPrevName(atSign)))?.data;
        final newXwingCert = (await keyStore.get(pqXwingCertName(atSign)))?.data;

        expect(prevXwingCert, equals(xwingCertBefore));
        expect(newXwingCert, isNotNull);
        expect(newXwingCert, isNot(equals(xwingCertBefore)));
      });

      test('data encrypted under prev key is still decapsulable after rotation',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishCert(atSign, keyStore);

        final kemResult = await AtPqc.xWing.encapsulate(mgr.xwingPublicKey);

        final oldPub = mgr.xwingPublicKey;
        await mgr.rotateCert(atSign, keyStore);

        final prevXwingCertRaw =
            (await keyStore.get(pqXwingCertPrevName(atSign)))?.data;
        expect(prevXwingCertRaw, isNotNull);
        final prevXwingCert = XWingCert.tryParse(prevXwingCertRaw!);
        expect(prevXwingCert!.xwingPublicKey, equals(oldPub),
            reason: 'Prev xwingCert public key must match the key before rotation');

        final persistedPrevSecret =
            (await keyStore.get(pqXwingSecretKeyPrevName(atSign)))?.data;
        expect(persistedPrevSecret, isNotNull,
            reason: 'Manager must retain prev secret key after rotation');

        final recovered = await AtPqc.xWing.decapsulate(
            base64.decode(persistedPrevSecret!), kemResult.ciphertext);
        expect(recovered, equals(kemResult.sharedSecret));
      });

      test(
          'decapsWithFallback recovers a peer that encapsulated to the prev xwingCert',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishCert(atSign, keyStore);

        // A peer encapsulates against the pre-rotation public key (as if it
        // cached the xwingCert across the rotation).
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
        await mgr.publishCert(atSign, keyStore);

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

    group('xwingCert expiry config', () {
      test('buildCert() honours the xwingCertExpiryDays ctor param', () async {
        final mgr = PqKeyManager(xwingCertExpiryDays: 7);
        await mgr.init(atSign, keyStore);
        await mgr.publishCert(atSign, keyStore);

        final xwingCertRaw = (await keyStore.get(pqXwingCertName(atSign)))?.data;
        final xwingCert = XWingCert.tryParse(xwingCertRaw!);

        final expected = DateTime.now().toUtc().add(const Duration(days: 7));
        expect(xwingCert!.validUntil.difference(expected).inMinutes.abs(),
            lessThan(5),
            reason: 'validUntil must reflect the ctor-supplied expiry, not '
                'the default');
      });
    });

    group('record namespacing', () {
      test('all PQ records except the xwingCert are stored under local:',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishCert(atSign, keyStore);
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
        expect(pqXwingCertName(atSign), startsWith('public:'));
        expect(await keyStore.exists(pqXwingCertName(atSign)), isTrue);
      });
    });
  });
}
