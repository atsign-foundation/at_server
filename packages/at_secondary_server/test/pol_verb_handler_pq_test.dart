import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/crypto/pq_key_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/pol_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:crypton/crypton.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

// ── fallback for InboundConnection ───────────────────────────────────────

class _FakeInboundConnection extends Fake implements InboundConnection {}

// ── test setup ────────────────────────────────────────────────────────────

late HiveKeyStoreFixture _fixture;
late AtKeyValueStore<String, AtData, AtMetaData?> _keyStore;
late MockAtAccessLog _accessLog;

Future<void> _setUp() async {
  _fixture = HiveKeyStoreFixture('test/hive_pq_pol');
  _keyStore = await _fixture.open(alice);
  AtSecondaryServerImpl.getInstance().currentAtSign = alice;
  _accessLog = MockAtAccessLog();
  when(() => _accessLog.insert(any(), any())).thenAnswer((_) async => 1);
}

Future<void> _tearDown() async => await _fixture.dispose();

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

  setUpAll(() {
    registerFallbackValue(_FakeInboundConnection());
  });

  setUp(_setUp);
  tearDown(_tearDown);

  // ── PQ mode ──────────────────────────────────────────────────────────────

  group('pol_verb_handler PQ mode', () {
    test(
        'matching PQ confirmation tags → isPolAuthenticated = true, no RSA lookup',
        () async {
      final ks = _keyStore;
      const sessionId = '_pq-sess-001';

      // Both sides derive the same HKDF key-confirmation tag from the shared
      // secret, bound to the handshake (sessionID || fromAtSign). The raw
      // secret never appears on the wire or in storage.
      final ss = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final tag = deriveConfirmationTag(ss, '$sessionId$bob');
      final stored = 'pq:${base64Url.encode(tag)}';

      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = stored
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      // Remote (bob) returns the same tag with data: prefix.
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:$stored');

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

    test(
        'matches a rotation-grace-period candidate tag (comma-separated list)',
        () async {
      final ks = _keyStore;
      const sessionId = '_pq-sess-001b';

      // Alice's own confirmation tag, derived from the shared secret her side
      // computed (as if against bob's prev, pre-rotation key).
      final ss = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final tag = deriveConfirmationTag(ss, '$sessionId$bob');
      final storedTag = base64Url.encode(tag);
      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = 'pq:$storedTag'
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );

      // Bob's server retained a rotation grace-period key and stored BOTH the
      // current-key tag (which does not match) and the prev-key tag (which
      // does) as a comma-separated list.
      final unrelatedTag = base64Url.encode(Uint8List(32));

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:pq:$unrelatedTag,$storedTag');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);
      final response = Response();
      await handler.processVerb(response, HashMap<String, String?>(), inbound);

      final meta = inbound.metaData as InboundConnectionMetadata;
      expect(meta.isPolAuthenticated, isTrue);
      expect(response.data, equals('pol:$bob@'));
    });

    test('PQ confirmation tag mismatch → UnAuthenticatedException', () async {
      final ks = _keyStore;
      const sessionId = '_pq-sess-002';

      await ks.put(
        'public:$sessionId$bob',
        AtData()
          ..data = 'pq:localSecret=='
          ..metaData = (AtMetaData()..ttl = 60 * 1000),
      );

      final mockOcm = MockOutboundClientManager();
      final mockOc = MockOutboundClient();
      when(() => mockOcm.getClient(bob, any(), handshakeRequired: false))
          .thenAnswer((_) async => mockOc);
      when(() => mockOc.isConnectionCreated).thenReturn(true);
      when(() => mockOc.lookUp('$sessionId$bob', handshake: false))
          .thenAnswer((_) async => 'data:pq:differentSecret==');

      final handler = PolVerbHandler(ks, mockOcm, MockAtCacheManager(),
          accessLog: _accessLog);
      final inbound = _makeInbound(mockSocket, sessionId, bob);

      await expectLater(
        handler.processVerb(Response(), HashMap<String, String?>(), inbound),
        throwsA(isA<UnAuthenticatedException>()),
      );
    });

    test('stored secret missing → UnAuthenticatedException', () async {
      final ks = _keyStore;
      const sessionId = '_pq-sess-003';

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
      final ks = _keyStore;
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
      final ks = _keyStore;
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
      final ks = _keyStore;
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

      // Cache removed: legacy auth must NOT persist any peer PQ key material.
      expect(await ks.exists('cached:public:pq_xwing_cert$bob'), isFalse);
      expect(
          await ks.exists('cached:public:pq_signing_publickey$bob'), isFalse);
    });
  });

  // ── pol requires prior from ───────────────────────────────────────────────

  group('pol_verb_handler precondition', () {
    test('pol without prior from: → InvalidRequestException', () async {
      final ks = _keyStore;
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
