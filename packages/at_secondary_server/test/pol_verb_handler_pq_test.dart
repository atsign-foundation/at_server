import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/crypto/pol_signing_algos.dart';
import 'package:at_secondary/src/crypto/signing_key_constants.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pol_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:crypton/crypton.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Signs [challenge] with [algoId] (defaulting to [polAlgoMlDsa65]),
/// returning the `<type>:<sig>` cookie a prover would send plus the public
/// key a verifier would have cached at FROM time.
Future<({String cookie, String publicKey})> _peerSign(String challenge,
    {String? algoId}) async {
  final id = algoId ?? polAlgoMlDsa65;
  final algo = negotiableSigningAlgos[id]!;
  final kp = await algo.generateKeyPairB64();
  return (
    cookie: buildSignedCookie(id, await algo.signB64(challenge, kp.secretKey)),
    publicKey: kp.publicKey,
  );
}

/// Seeds the verifier's own FROM-time record — the challenge, the algorithm
/// it chose to demand (if any), and the peer's key for it — exactly as
/// [FromVerbHandler] would have stored it.
Future<void> _seedStoredChallenge(
    AtKeyValueStore<String, AtData, AtMetaData?> ks, String sessionId,
    {required String challenge, String? chosenAlgo, String? peerPublicKey}) {
  return ks.put(
    'public:$sessionId$bob',
    AtData()
      ..data = StoredPolChallenge(
              challenge: challenge,
              chosenAlgo: chosenAlgo,
              peerPublicKey: peerPublicKey)
          .encode()
      ..metaData = (AtMetaData()..ttl = 60 * 1000),
  );
}

// ── fallback for InboundConnection ───────────────────────────────────────

class _FakeInboundConnection extends Fake implements InboundConnection {}

// ── test setup ────────────────────────────────────────────────────────────

late MockAtAccessLog _accessLog;

Future<void> _setUp() async {
  await verbTestsSetUp();
  AtSecondaryServerImpl.getInstance().currentAtSign = alice;
  _accessLog = MockAtAccessLog();
  when(() => _accessLog.insert(any(), any())).thenAnswer((_) async => 1);
}

Future<void> _tearDown() async => await verbTestsTearDown();

// ── helper: build an InboundConnection with from-verb metadata ────────────

InboundConnectionImpl _makeInbound(
    FakeSocket sock, String sessionId, Atsign fromAtSign) {
  final conn = InboundConnectionImpl(sock, sessionId);
  final meta = conn.metaData as InboundConnectionMetadata;
  meta
    ..from = true
    ..fromAtSign = fromAtSign;
  return conn;
}

// ─────────────────────────────────────────────────────────────────────────

void main() {
  verbTestsSetUpLogging();
  FakeSocket mockSocket = FakeSocket();

  setUpAll(() async {
    await verbTestsSetUpAll();
    registerFallbackValue(_FakeInboundConnection());
  });

  setUp(_setUp);
  tearDown(_tearDown);

  // ── PQ mode: the verifier's own stored decision is authoritative ────────

  group('pol_verb_handler PQ mode', () {
    test(
        'valid ML-DSA signature against the demanded type → '
        'isPolAuthenticated = true, no key lookups', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-001';
      const challenge = 'pq-uuid-challenge';

      final peer = await _peerSign(challenge);
      await _seedStoredChallenge(ks, sessionId,
          challenge: challenge,
          chosenAlgo: polAlgoMlDsa65,
          peerPublicKey: peer.publicKey);

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:${peer.cookie}');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);
      final response = Response();
      await handler.processVerb(response, HashMap<String, String?>(), inbound);

      final meta = inbound.metaData as InboundConnectionMetadata;
      expect(meta.isPolAuthenticated, isTrue);
      expect(response.data, equals('pol:$bob@'));
      // The key was already cached at FROM time — POL must not fetch any
      // record (PQ or legacy) to verify a demanded-and-honoured signature.
      verifyNever(() => mockOc.plookUp(any()));
    });

    test('signature over a different challenge → UnAuthenticatedException',
        () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-002';

      // Peer signed a *different* challenge than the one alice stored.
      final peer = await _peerSign('a-forged-challenge');
      await _seedStoredChallenge(ks, sessionId,
          challenge: 'the-real-challenge',
          chosenAlgo: polAlgoMlDsa65,
          peerPublicKey: peer.publicKey);

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:${peer.cookie}');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    // The core claim of the verifier-chosen-algorithm design: the cookie's own
    // `<type>:` tag is never consulted. A prover that signs with something
    // other than the demanded type still lands on verification against the
    // demanded type's key, and simply fails.
    test(
        'cookie tagged with a weaker/different algorithm than demanded → '
        'rejected, tag ignored', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-003';
      const challenge = 'algo-challenge';

      // Verifier demanded ml-dsa-65 and cached bob's key for it.
      final demanded = await _peerSign(challenge);
      await _seedStoredChallenge(ks, sessionId,
          challenge: challenge,
          chosenAlgo: polAlgoMlDsa65,
          peerPublicKey: demanded.publicKey);

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      // Bob's cookie names some other algorithm entirely and carries
      // unrelated bytes — the tag must never steer verification.
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:pq-future-algo:AAAA');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
      // Rejected without ever fetching a record for "pq-future-algo" — the
      // tag was never looked at, so there was nothing to fetch it for.
      verifyNever(() => mockOc.plookUp(any()));
    });

    test(
        'an untagged (legacy-shaped) cookie against a challenge demanding PQ '
        '→ rejected', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-004';
      const challenge = 'untagged-vs-pq-challenge';

      final demanded = await _peerSign(challenge);
      await _seedStoredChallenge(ks, sessionId,
          challenge: challenge,
          chosenAlgo: polAlgoMlDsa65,
          peerPublicKey: demanded.publicKey);

      final bobKp = RSAKeypair.fromRandom();
      final rsaCookie =
          SecondaryUtil.signChallenge(challenge, bobKp.privateKey.toString());

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:$rsaCookie');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test(
        'demanded algorithm retired from the registry between FROM and POL → '
        'UnAuthenticatedException', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-005';
      const challenge = 'retired-algo-challenge';

      // A type this server chose at FROM time but no longer knows by POL —
      // should not happen absent a live retirement mid-handshake, but must
      // fail the auth rather than crash.
      await _seedStoredChallenge(ks, sessionId,
          challenge: challenge,
          chosenAlgo: 'retired-algo',
          peerPublicKey: 'irrelevant');

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:retired-algo:AAAA');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test(
        'a demanded algorithm with no cached peer key → AtException '
        '(defensive; FromVerbHandler always sets both together)', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-006';
      const challenge = 'no-cached-key-challenge';

      await _seedStoredChallenge(ks, sessionId,
          challenge: challenge, chosenAlgo: polAlgoMlDsa65);

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:$polAlgoMlDsa65:AAAA');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<AtException>()),
      );
    });

    // Peer-controlled bytes that at_chops reports as StateError /
    // FormatException, not AtException. Without the verify()-wrapping guards
    // they escape as a shout-logged internal server error rather than the
    // auth failure they are.
    group('malformed peer material fails as an auth error, not a 500', () {
      Future<void> expectAuthFailure(
          {required String sessionId,
          required String cookie,
          required String peerPublicKey}) async {
        final ks = keyValueStore;
        await _seedStoredChallenge(ks, sessionId,
            challenge: 'a-challenge',
            chosenAlgo: polAlgoMlDsa65,
            peerPublicKey: peerPublicKey);

        final mockOcm = MockOutboundClientManager();
        final mockOc = MockOutboundClient();
        when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
            .thenAnswer((_) async => mockOc);
        when(() => mockOc.isConnectionCreated).thenReturn(true);
        when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
            .thenAnswer((_) async => 'data:$cookie');

        final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
            accessLog: _accessLog);
        await expectLater(
          handler.processVerb(Response(), HashMap<String, String?>(),
              _makeInbound(mockSocket, sessionId, bob)),
          throwsA(isA<UnAuthenticatedException>()),
        );
      }

      test('cached public key of the wrong length', () async {
        await expectAuthFailure(
          sessionId: '_pq-bad-key',
          // A correctly-sized ML-DSA-65 signature (FIPS 204), so the failure is
          // unambiguously the key length and not the signature length.
          cookie: buildSignedCookie(
              polAlgoMlDsa65, base64.encode(List<int>.filled(3309, 0))),
          peerPublicKey: base64.encode(List<int>.filled(100, 1)),
        );
      });

      test('signature that is not valid base64', () async {
        final peer = await _peerSign('a-challenge');
        await expectAuthFailure(
          sessionId: '_pq-bad-b64',
          cookie: buildSignedCookie(polAlgoMlDsa65, 'not!valid!base64'),
          peerPublicKey: peer.publicKey,
        );
      });

      test('signature of the wrong length', () async {
        final peer = await _peerSign('a-challenge');
        await expectAuthFailure(
          sessionId: '_pq-bad-sig-len',
          cookie: buildSignedCookie(
              polAlgoMlDsa65, base64.encode(List<int>.filled(10, 0))),
          peerPublicKey: peer.publicKey,
        );
      });
    });

    test('stored secret missing → UnAuthenticatedException', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-007';

      // No stored secret pre-populated.
      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });
  });

  // ── Legacy RSA mode: nothing demanded, key fetched fresh at POL ─────────

  group('pol_verb_handler legacy RSA mode', () {
    test('valid RSA signature → isPolAuthenticated = true', () async {
      final ks = keyValueStore;
      const sessionId = '_rsa-sess-001';
      const challenge = 'some-uuid-challenge';

      // Alice demanded nothing (no mutual PQ type) — the legacy branch.
      await _seedStoredChallenge(ks, sessionId, challenge: challenge);

      final bobKp = RSAKeypair.fromRandom();
      final signedChallenge =
          SecondaryUtil.signChallenge(challenge, bobKp.privateKey.toString());

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:$signedChallenge');
      when(() => mockOc.plookUp('signing_publickey$bob'))
          .thenAnswer((_) async => 'data:${bobKp.publicKey}');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);
      final response = Response();
      await handler.processVerb(response, HashMap<String, String?>(), inbound);

      final meta = inbound.metaData as InboundConnectionMetadata;
      expect(meta.isPolAuthenticated, isTrue);
      expect(response.data, equals('pol:$bob@'));
    });

    test('invalid RSA signature → UnAuthenticatedException', () async {
      final ks = keyValueStore;
      const sessionId = '_rsa-sess-002';
      const challenge = 'another-uuid-challenge';

      await _seedStoredChallenge(ks, sessionId, challenge: challenge);

      final bobKp = RSAKeypair.fromRandom();
      final wrongKp = RSAKeypair.fromRandom();
      // Sign with *wrong* private key.
      final badSignature =
          SecondaryUtil.signChallenge(challenge, wrongKp.privateKey.toString());

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:$badSignature');
      when(() => mockOc.plookUp('signing_publickey$bob'))
          .thenAnswer((_) async => 'data:${bobKp.publicKey}');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test('malformed peer RSA key fails as an auth error, not a 500', () async {
      final ks = keyValueStore;
      const sessionId = '_rsa-sess-003';
      const challenge = 'malformed-key-challenge';

      await _seedStoredChallenge(ks, sessionId, challenge: challenge);

      final bobKp = RSAKeypair.fromRandom();
      final signedChallenge =
          SecondaryUtil.signChallenge(challenge, bobKp.privateKey.toString());

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:$signedChallenge');
      // Junk, not a parseable RSA key.
      when(() => mockOc.plookUp('signing_publickey$bob'))
          .thenAnswer((_) async => 'data:not-an-rsa-key');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test('peer publishes no legacy RSA key → AtException', () async {
      final ks = keyValueStore;
      const sessionId = '_rsa-sess-004';
      const challenge = 'no-legacy-key-challenge';

      await _seedStoredChallenge(ks, sessionId, challenge: challenge);

      final bobKp = RSAKeypair.fromRandom();
      final signedChallenge =
          SecondaryUtil.signChallenge(challenge, bobKp.privateKey.toString());

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:$signedChallenge');
      when(() => mockOc.plookUp('signing_publickey$bob'))
          .thenAnswer((_) async => null);

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<AtException>()),
      );
    });
  });

  // ── pol requires prior from ───────────────────────────────────────────────

  group('pol_verb_handler precondition', () {
    test('pol without prior from: → InvalidRequestException', () async {
      final ks = keyValueStore;
      final mockOcm = MockOutboundClientManager();
      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);

      // Connection WITHOUT from = true set.
      final inbound = InboundConnectionImpl(mockSocket, '_no-from-sess');

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<InvalidRequestException>()),
      );
    });
  });
}
