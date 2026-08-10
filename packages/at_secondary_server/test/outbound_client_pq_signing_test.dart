import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/crypto/pol_signing_algos.dart';
import 'package:at_secondary/src/crypto/signing_key_constants.dart';
import 'package:at_secondary/src/crypto/signing_key_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:test/test.dart';

import 'test_utils.dart';
import 'util/fake_signing_algo.dart';

/// Prover-side signing.
///
/// Note what is absent: any selection logic, and any wire stub. The verifier
/// chooses the algorithm and embeds that one choice in the challenge it signs
/// us — the prover only honours it or refuses, and reads it out of the
/// challenge it already has, so this touches no socket at all.
void main() {
  OutboundConnectionFactory outboundConnectionFactory =
      DefaultOutboundConnectionFactory(clientCertificateRequired: false);

  verbTestsSetUpLogging();
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  OutboundClient makeClient({SigningKeyManager? signingKeyManager}) {
    final inbound = InboundConnectionImpl(FakeSocket(), 'test-session');
    return OutboundClient(
      inbound,
      bob,
      AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
      true,
      outboundConnectionFactory,
      signingKeyManager ??
          AtSecondaryServerImpl.getInstance().signingKeyManager,
    );
  }

  /// A decoded bound challenge demanding [algo], as a verifier would issue.
  BoundPolChallenge demanding(String? algo) =>
      BoundPolChallenge(verifier: bob, chosenAlgo: algo);

  group('selectAndSignChallenge', () {
    late SigningKeyManager initialised;

    setUp(() async {
      initialised = SigningKeyManager();
      await initialised.init(alice.toString(), keyValueStore);
    });

    test('verifier demands ml-dsa-65, we hold the key → tagged cookie',
        () async {
      final cookie = await makeClient(signingKeyManager: initialised)
          .selectAndSignChallenge('a-challenge', demanding(polAlgoMlDsa65));
      expect(cookie, startsWith('$polAlgoMlDsa65:'));
    });

    test('verifier demands nothing → legacy untagged RSA cookie', () async {
      final cookie = await makeClient(signingKeyManager: initialised)
          .selectAndSignChallenge('a-challenge', demanding(null));
      expect(parseSignedCookie(cookie).type, isNull,
          reason: 'a pre-negotiation or PQ-disabled verifier must still be '
              'able to verify us, and it only understands the untagged form');
    });

    test('legacy bare challenge (null bound) → legacy untagged RSA cookie',
        () async {
      final cookie = await makeClient(signingKeyManager: initialised)
          .selectAndSignChallenge('a-challenge', null);
      expect(parseSignedCookie(cookie).type, isNull);
    });

    test('verifier demands a type we do not hold → refused, not substituted',
        () async {
      await expectLater(
        makeClient(signingKeyManager: initialised)
            .selectAndSignChallenge('a-challenge', demanding('pq-9000')),
        throwsA(isA<HandShakeException>()),
        reason: 'silently substituting a weaker type would defeat the whole '
            'point of the verifier choosing',
      );
    });

    test('keys not initialised but verifier demands PQ → refused', () async {
      await expectLater(
        makeClient() // singleton manager, never init'd here
            .selectAndSignChallenge('a-challenge', demanding(polAlgoMlDsa65)),
        throwsA(isA<HandShakeException>()),
      );
    });

    test('both paths sign the challenge verbatim', () async {
      const challenge = 'the-bound-challenge';
      final algo = negotiableSigningAlgos[polAlgoMlDsa65]!;

      final pqCookie = await makeClient(signingKeyManager: initialised)
          .selectAndSignChallenge(challenge, demanding(polAlgoMlDsa65));
      final parsed = parseSignedCookie(pqCookie);
      expect(
          await algo.verifyB64(challenge, parsed.signature,
              initialised.publicKeyFor(polAlgoMlDsa65)!),
          isTrue);

      final rsaCookie = await makeClient(signingKeyManager: initialised)
          .selectAndSignChallenge(challenge, demanding(null));
      expect(
          rsaCookie,
          equals(SecondaryUtil.signChallenge(
              challenge, AtSecondaryServerImpl.getInstance().signingKey)),
          reason: 'the RSA path must sign the challenge verbatim, exactly as '
              'every deployed at_server already does');
    });

    test('the demand is covered by the signature, so stripping it is detected',
        () async {
      // The tamper-evidence claim, asserted rather than argued: an attacker who
      // strips `alg` to force a downgrade changes the bytes the prover signed,
      // so the verifier's check against its stored original fails.
      final issued =
          SecondaryUtil.buildBoundPolChallenge(bob, chosenAlgo: polAlgoMlDsa65);
      final stripped = SecondaryUtil.buildBoundPolChallenge(bob);
      expect(stripped, isNot(equals(issued)));

      final algo = negotiableSigningAlgos[polAlgoMlDsa65]!;
      final cookie = await makeClient(signingKeyManager: initialised)
          .selectAndSignChallenge(issued, demanding(polAlgoMlDsa65));
      final sig = parseSignedCookie(cookie).signature;
      final pub = initialised.publicKeyFor(polAlgoMlDsa65)!;

      expect(await algo.verifyB64(issued, sig, pub), isTrue);
      expect(await algo.verifyB64(stripped, sig, pub), isFalse,
          reason: 'a mutated challenge must not verify — that is what makes '
              'the in-band demand tamper-evident rather than strippable');
    });
  });

  group('a second negotiable algorithm', () {
    // at_chops ships one PQ signature algorithm, so a stand-in is the only way
    // to exercise "hold a key for whichever type is demanded" rather than
    // "hold a key for the only type there is".
    late SigningKeyManager initialised;

    setUp(() async {
      initialised = SigningKeyManager.withAlgos(
          {fakeStrongerAlgoId: fakeStrongerAlgo, ...negotiableSigningAlgos});
      await initialised.init(alice.toString(), keyValueStore);
    });

    test('holds a key for every negotiable type', () {
      expect(initialised.availableTypes,
          equals([fakeStrongerAlgoId, polAlgoMlDsa65]));
    });

    test('signs with whichever of our types the verifier demands', () async {
      final cookie = await makeClient(signingKeyManager: initialised)
          .selectAndSignChallenge('c', demanding(fakeStrongerAlgoId));
      expect(parseSignedCookie(cookie).type, equals(fakeStrongerAlgoId));
    });

    test('publishes a key for every negotiable type in one record', () async {
      final raw = (await keyValueStore
              .get(signingPublicKeysRecordKey(alice.toString())))
          ?.data;
      final decoded = jsonDecode(raw!) as Map;
      expect(decoded.keys.toSet(), equals({fakeStrongerAlgoId, polAlgoMlDsa65}),
          reason: 'one record holds every type — that is the whole point of it '
              'being generically named');
      expect(decoded.containsKey(polAlgoRsaSha256), isFalse,
          reason:
              'RSA lives at signing_publickey and is never duplicated here');
    });
  });
}
