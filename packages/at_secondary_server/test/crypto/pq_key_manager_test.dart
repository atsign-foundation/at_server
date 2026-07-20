import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/crypto/pq_key_manager.dart';
import 'package:at_secondary/src/crypto/pq_signing_public_record.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  group('pq_signing_public_record', () {
    test('build → parse round-trips the key for its algorithm', () {
      final key = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final json = buildPqSigningPublicRecord({pqAlgoMlDsa65: key});
      // JSON is a map keyed by algorithm id.
      expect(jsonDecode(json), equals({pqAlgoMlDsa65: base64.encode(key)}));
      expect(pqSigningKeyForAlgo(json, pqAlgoMlDsa65), equals(key));
    });

    test('parse returns null for a missing algorithm or malformed input', () {
      final json = buildPqSigningPublicRecord(
          {pqAlgoMlDsa65: Uint8List.fromList([1, 2, 3])});
      expect(pqSigningKeyForAlgo(json, 'no-such-algo'), isNull);
      expect(pqSigningKeyForAlgo('not-json', pqAlgoMlDsa65), isNull);
      expect(pqSigningKeyForAlgo('{"ml-dsa-65": 123}', pqAlgoMlDsa65), isNull);
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
      test('isInitialised is false before init() and true after', () async {
        final mgr = PqKeyManager();
        expect(mgr.isInitialised, isFalse);
        await mgr.init(atSign, keyStore);
        expect(mgr.isInitialised, isTrue);
      });

      test('reloads the same keypair from the keystore on a second init',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        final pubBefore = mgr.mlDsaPublicKey;

        final mgr2 = PqKeyManager();
        await mgr2.init(atSign, keyStore);
        expect(mgr2.mlDsaPublicKey, equals(pubBefore),
            reason: 'existing key material must be loaded, not regenerated');
      });

      test('partial key material regenerates rather than throwing', () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        final pubBefore = mgr.mlDsaPublicKey;

        // Public companion record deleted while the secret survives.
        await keyStore.remove(pqSigningPublicKeyName(atSign));

        final mgr2 = PqKeyManager();
        await expectLater(mgr2.init(atSign, keyStore), completes);
        expect(mgr2.mlDsaPublicKey, isNot(equals(pubBefore)),
            reason: 'partial material must trigger regeneration');
      });
    });

    group('publishPublicKey()', () {
      test('publishes a JSON record carrying the ml-dsa-65 public key',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);
        await mgr.publishPublicKey(atSign, keyStore);

        final raw =
            (await keyStore.get(pqSigningPublicKeyRecordName(atSign)))?.data;
        expect(raw, isNotNull);
        final map = jsonDecode(raw!) as Map<String, dynamic>;
        expect(map.keys, equals({pqAlgoMlDsa65}),
            reason: 'exactly the supported algorithm is offered today');
        expect(pqSigningKeyForAlgo(raw, pqAlgoMlDsa65),
            equals(mgr.mlDsaPublicKey));
      });

      test('throws if called before init()', () async {
        final mgr = PqKeyManager();
        expect(() => mgr.publishPublicKey(atSign, keyStore),
            throwsA(isA<StateError>()));
      });
    });

    group('signChallenge()', () {
      test('produces a pq:<algo>:<sig> cookie that verifies against the '
          'published key', () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);

        const challenge = 'a-fresh-uuid-challenge';
        final cookie = await mgr.signChallenge(challenge);

        final parts = cookie.split(':');
        expect(parts[0], equals('pq'));
        expect(parts[1], equals(pqAlgoMlDsa65));
        expect(parts.length, equals(3));

        final isValid = await AtPqc.mlDsa65.verifyBytes(
            utf8.encode(challenge),
            signature: base64.decode(parts[2]),
            publicKey: mgr.mlDsaPublicKey);
        expect(isValid, isTrue);
      });

      test('signature does not verify against a different challenge',
          () async {
        final mgr = PqKeyManager();
        await mgr.init(atSign, keyStore);

        final cookie = await mgr.signChallenge('challenge-one');
        final sig = base64.decode(cookie.split(':')[2]);

        final isValid = await AtPqc.mlDsa65.verifyBytes(
            utf8.encode('a-different-challenge'),
            signature: sig,
            publicKey: mgr.mlDsaPublicKey);
        expect(isValid, isFalse);
      });

      test('throws if called before init()', () async {
        final mgr = PqKeyManager();
        expect(() => mgr.signChallenge('x'), throwsA(isA<StateError>()));
      });
    });
  });
}
