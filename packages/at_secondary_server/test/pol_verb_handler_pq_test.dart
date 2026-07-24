import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/crypto/pq_signing_public_record.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pol_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:crypton/crypton.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// A peer's PQ signing material: the `pq:<algo>:<sig>` cookie it would store
/// for [challenge], and the JSON public-key record a verifier fetches.
class _PeerSigner {
  final String cookie;
  final String record;
  _PeerSigner(this.cookie, this.record);

  static Future<_PeerSigner> sign(String challenge) async {
    final kp = await MlDsa65KeyPair.generate();
    final sig = await AtPqc.mlDsa65
        .signBytes(utf8.encode(challenge), secretKey: kp.privateKeyBytes);
    return _PeerSigner(
      'pq:$pqAlgoMlDsa65:${base64.encode(sig)}',
      buildPqSigningPublicRecord({pqAlgoMlDsa65: kp.publicKeyBytes}),
    );
  }
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

// ── helper: the payload the verifier (alice) reconstructs and expects the
// prover (bob) to have signed for a given session + challenge ─────────────

String _expectedPayload(String sessionId, String challenge) =>
    SecondaryUtil.buildPolChallengePayload(
      verifierAtSign: alice.toString(),
      proverAtSign: bob.toString(),
      sessionId: '$sessionId$bob',
      challenge: challenge,
    );

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

  // ── PQ mode ──────────────────────────────────────────────────────────────

  group('pol_verb_handler PQ mode', () {
    test('valid ML-DSA signature → isPolAuthenticated = true, no RSA lookup',
        () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-001';
      const challenge = 'pq-uuid-challenge';

      // Alice (verifier) stored the UUID she issued at FROM time.
      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = challenge
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );
      final peer =
          await _PeerSigner.sign(_expectedPayload(sessionId, challenge));

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:${peer.cookie}');
      when(() => mockOc.plookUp('$pqSigningPublicKeyRecordNamePart$bob'))
          .thenAnswer((_) async => 'data:${peer.record}');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);
      final response = Response();
      await handler.processVerb(response, HashMap<String, String?>(), inbound);

      final meta = inbound.metaData as InboundConnectionMetadata;
      expect(meta.isPolAuthenticated, isTrue);
      expect(response.data, equals('pol:$bob@'));
      // PQ mode must not fall back to the legacy RSA signing-key lookup.
      verifyNever(() => mockOc.plookUp('signing_publickey$bob'));
    });

    test('signature over a different challenge → UnAuthenticatedException',
        () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-002';

      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = 'the-real-challenge'
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );
      // Peer signed a payload for a *different* challenge than the one Alice
      // stored.
      final peer = await _PeerSigner.sign(
          _expectedPayload(sessionId, 'a-forged-challenge'));

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:${peer.cookie}');
      when(() => mockOc.plookUp('$pqSigningPublicKeyRecordNamePart$bob'))
          .thenAnswer((_) async => 'data:${peer.record}');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test('unsupported algorithm tag → UnAuthenticatedException', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-003';
      const challenge = 'algo-challenge';

      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = challenge
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      // Cookie advertises an algorithm the verifier does not support.
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:pq:pq-future-algo:AAAA');
      when(() => mockOc.plookUp('$pqSigningPublicKeyRecordNamePart$bob'))
          .thenAnswer((_) async => null);

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test('peer publishes no PQ signing key record → AtException', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-004';
      const challenge = 'no-record-challenge';

      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = challenge
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );
      final peer =
          await _PeerSigner.sign(_expectedPayload(sessionId, challenge));

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:${peer.cookie}');
      // Record lookup returns null (peer published nothing).
      when(() => mockOc.plookUp('$pqSigningPublicKeyRecordNamePart$bob'))
          .thenAnswer((_) async => null);

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<AtException>()),
      );
    });

    // Peer-controlled bytes that at_chops reports as StateError /
    // FormatException rather than an AtException. Without the guards in
    // _verifyPqSignature these escape as a shout-logged internal server
    // error; a peer sending garbage is an auth failure, not a server fault.
    group('malformed peer material fails as an auth error, not a 500', () {
      /// Drives a full pol with [cookie] as the peer's stored cookie and
      /// [record] as its published signing-key record.
      Future<void> expectAuthFailure(
          {required String sessionId,
          required String cookie,
          required String record}) async {
        final ks = keyValueStore;
        await ks.put(
          'public:$sessionId$bob',
          AtData()
            ..data = 'a-challenge'
            ..metaData = (AtMetaData()..ttl = 60 * 1000),
        );

        final mockOcm = MockOutboundClientManager();
        final mockOc = MockOutboundClient();
        when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
            .thenAnswer((_) async => mockOc);
        when(() => mockOc.isConnectionCreated).thenReturn(true);
        when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
            .thenAnswer((_) async => 'data:$cookie');
        when(() => mockOc.plookUp('$pqSigningPublicKeyRecordNamePart$bob'))
            .thenAnswer((_) async => 'data:$record');

        final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
            accessLog: _accessLog);
        await expectLater(
          handler.processVerb(Response(), HashMap<String, String?>(),
              _makeInbound(mockSocket, sessionId, bob)),
          throwsA(isA<UnAuthenticatedException>()),
        );
      }

      test('public key of the wrong length', () async {
        await expectAuthFailure(
          sessionId: '_pq-bad-key',
          cookie: 'pq:$pqAlgoMlDsa65:${base64.encode(List<int>.filled(
            mlDsa65SignatureLength,
            0,
          ))}',
          record: buildPqSigningPublicRecord(
              {pqAlgoMlDsa65: Uint8List.fromList(List<int>.filled(100, 1))}),
        );
      });

      test('signature that is not valid base64', () async {
        final kp = await MlDsa65KeyPair.generate();
        await expectAuthFailure(
          sessionId: '_pq-bad-b64',
          cookie: 'pq:$pqAlgoMlDsa65:not!valid!base64',
          record:
              buildPqSigningPublicRecord({pqAlgoMlDsa65: kp.publicKeyBytes}),
        );
      });

      test('signature of the wrong length', () async {
        final kp = await MlDsa65KeyPair.generate();
        await expectAuthFailure(
          sessionId: '_pq-bad-sig-len',
          cookie: 'pq:$pqAlgoMlDsa65:${base64.encode(List<int>.filled(10, 0))}',
          record:
              buildPqSigningPublicRecord({pqAlgoMlDsa65: kp.publicKeyBytes}),
        );
      });
    });

    test('stored secret missing → UnAuthenticatedException', () async {
      final ks = keyValueStore;
      const sessionId = '_pq-sess-005';

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

  // ── Legacy RSA mode ───────────────────────────────────────────────────────

  group('pol_verb_handler legacy RSA mode', () {
    test('valid RSA signature → isPolAuthenticated = true', () async {
      final ks = keyValueStore;
      const sessionId = '_rsa-sess-001';
      const challenge = 'some-uuid-challenge';

      // Alice stored the raw UUID as the secret.
      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = challenge
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );

      // Generate a fresh RSA keypair for @bob.
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

      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = challenge
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );

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
  });

  // ── No PQ key caching (cache removed) ─────────────────────────────────────

  group('pol_verb_handler no PQ caching', () {
    test('after legacy RSA success, no PQ keys are cached in keystore',
        () async {
      final ks = keyValueStore;
      const sessionId = '_rsa-cache-001';
      const challenge = 'cache-test-challenge';

      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = challenge
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );

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
      await handler.processVerb(
          Response(), HashMap<String, String?>(), inbound);

      // Legacy auth must NOT persist any peer PQ key material.
      expect(
          await ks.exists('cached:public:pq_signing_publickey$bob'), isFalse);
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
