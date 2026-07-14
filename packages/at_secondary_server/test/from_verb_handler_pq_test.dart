import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late HiveKeyStoreFixture fixture;
  late AtKeyValueStore<String, AtData, AtMetaData?> keyStoreManager;
  late MockSecureSocket mockSecureSocket;
  late MockAtAccessLog mockAccessLog;

  verbTestsSetUpLogging();

  setUpAll(() {
    registerFallbackValue(SocketOption.tcpNoDelay);
    registerFallbackValue(DummyInboundConnection());
  });

  setUp(() async {
    fixture = HiveKeyStoreFixture('test/hive_pq_from');
    keyStoreManager = await fixture.open(alice);

    // Inject a stub secondary address finder so _verifyFromAtSign doesn't
    // make a real root-server call when clientCertificateRequired = true.
    final mockSaf = MockSecondaryAddressFinder();
    when(() => mockSaf.findSecondary(any()))
        .thenAnswer((_) async => at_lookup.SecondaryAddress('localhost', 9999));
    AtSecondaryServerImpl.getInstance().secondaryAddressFinder = mockSaf;
    AtSecondaryServerImpl.getInstance().currentAtSign = alice;

    mockSecureSocket = MockSecureSocket();
    when(() => mockSecureSocket.peerCertificate).thenReturn(null);
    when(() => mockSecureSocket.setOption(any(), any())).thenReturn(true);
    when(() => mockSecureSocket.address)
        .thenReturn(InternetAddress.loopbackIPv4);
    when(() => mockSecureSocket.port).thenReturn(0);
    when(() => mockSecureSocket.remoteAddress)
        .thenReturn(InternetAddress.loopbackIPv4);
    when(() => mockSecureSocket.remotePort).thenReturn(0);
    when(() => mockSecureSocket.done)
        .thenAnswer((_) => Completer<void>().future);
    when(() => mockSecureSocket.listen(any(),
            onDone: any(named: 'onDone'), onError: any(named: 'onError')))
        .thenAnswer((_) => MockStreamSubscription());

    mockAccessLog = MockAtAccessLog();
    when(() => mockAccessLog.insert(any(), any())).thenAnswer((_) async => 1);
  });

  tearDown(() async => await fixture.dispose());

  group('from_verb_handler PQ path', () {
    test('no PQ cert available (peer plookUp returns null) → legacy UUID '
        'proof (no pq: prefix)', () async {
      final ks = keyStoreManager;

      final mockMgr = mockOcmServingPeerCert(null);
      final handler = FromVerbHandler(ks, mockMgr, accessLog: mockAccessLog);
      final atConnection =
          InboundConnectionImpl(mockSecureSocket, 'sess-001');
      (atConnection.metaData as InboundConnectionMetadata).isStream = true;

      final verbParams = HashMap<String, String?>();
      verbParams['atSign'] = bob.toString();

      final response = Response();
      await handler.processVerb(response, verbParams, atConnection);

      expect(response.data, isNotNull);
      // No PQ cert → legacy UUID path → no 'pq:' in the proof token
      final parts = response.data!.split(':');
      // format: proof:sessionID@bob:token
      expect(parts[0], 'proof');
      expect(parts.last.startsWith('pq'), isFalse,
          reason: 'Expected UUID proof, not PQ ciphertext');

      // Stored secret must NOT have pq: prefix
      final stored = (await ks.get('public:sess-001$bob'))?.data;
      expect(stored, isNotNull);
      expect(stored!.startsWith('pq:'), isFalse);
    });

    test('valid PQ cert live-fetched → PQ proof (pq: prefix in token)',
        () async {
      final ks = keyStoreManager;

      final certJson = await buildSignedPeerCertJson(
          validUntil: DateTime.now().toUtc().add(const Duration(days: 365)));
      final mockMgr = mockOcmServingPeerCert(certJson);

      final handler = FromVerbHandler(ks, mockMgr, accessLog: mockAccessLog);
      final atConnection =
          InboundConnectionImpl(mockSecureSocket, 'sess-002');
      (atConnection.metaData as InboundConnectionMetadata).isStream = true;

      final verbParams = HashMap<String, String?>();
      verbParams['atSign'] = bob.toString();

      final response = Response();
      await handler.processVerb(response, verbParams, atConnection);

      expect(response.data, isNotNull);
      // PQ cert present → PQ proof
      // format: proof:sess-002@bob:pq:<ciphertext>
      // Split on ':' → [..., 'pq', '<ciphertextB64>']
      // The second-to-last token is the 'pq' marker.
      final parts = response.data!.split(':');
      expect(parts[parts.length - 2], equals('pq'),
          reason: 'Expected "pq" marker in proof response');

      // Stored value must be a 'pq:' key-confirmation tag (32 bytes) — NOT the
      // raw shared secret, which must never be persisted/transmitted.
      final stored = (await ks.get('public:sess-002$bob'))?.data;
      expect(stored, isNotNull);
      expect(stored!.startsWith('pq:'), isTrue);
      expect(base64Url.decode(stored.substring('pq:'.length)).length,
          equals(32));
    });

    test('expired PQ cert live-fetched → falls back to legacy UUID', () async {
      final ks = keyStoreManager;

      final certJson = await buildSignedPeerCertJson(
          validUntil: DateTime.now().toUtc().subtract(const Duration(days: 1)));
      final mockMgr = mockOcmServingPeerCert(certJson);

      final handler = FromVerbHandler(ks, mockMgr, accessLog: mockAccessLog);
      final atConnection =
          InboundConnectionImpl(mockSecureSocket, 'sess-003');
      (atConnection.metaData as InboundConnectionMetadata).isStream = true;

      final verbParams = HashMap<String, String?>();
      verbParams['atSign'] = bob.toString();

      final response = Response();
      await handler.processVerb(response, verbParams, atConnection);

      // Expired cert → verify() returns false → UUID fallback
      expect(response.data, isNotNull);
      final token = response.data!.split(':').last;
      expect(token.startsWith('pq'), isFalse,
          reason: 'Expired cert should fall back to UUID');
    });

    test('unparseable PQ cert → falls back to legacy UUID', () async {
      final ks = keyStoreManager;

      final mockMgr = mockOcmServingPeerCert('not-a-valid-cert');
      final handler = FromVerbHandler(ks, mockMgr, accessLog: mockAccessLog);
      final atConnection =
          InboundConnectionImpl(mockSecureSocket, 'sess-parse');
      (atConnection.metaData as InboundConnectionMetadata).isStream = true;

      final verbParams = HashMap<String, String?>();
      verbParams['atSign'] = bob.toString();

      final response = Response();
      await handler.processVerb(response, verbParams, atConnection);

      final token = response.data!.split(':').last;
      expect(token.startsWith('pq'), isFalse,
          reason: 'Unparseable cert should fall back to UUID');
    });

    test('AT_DISABLE_PQ_AUTH forces UUID path even with valid PQ cert',
        () async {
      final ks = keyStoreManager;

      final certJson = await buildSignedPeerCertJson(
          validUntil: DateTime.now().toUtc().add(const Duration(days: 365)));
      final mockMgr = mockOcmServingPeerCert(certJson);

      final handler = FromVerbHandler(ks, mockMgr,
          accessLog: mockAccessLog, disablePqAuth: true);
      final atConnection =
          InboundConnectionImpl(mockSecureSocket, 'sess-dpa');
      (atConnection.metaData as InboundConnectionMetadata).isStream = true;

      final verbParams = HashMap<String, String?>();
      verbParams['atSign'] = bob.toString();

      final response = Response();
      await handler.processVerb(response, verbParams, atConnection);

      // Despite valid PQ cert, the flag forces the UUID/RSA path.
      final parts = response.data!.split(':');
      expect(parts[0], 'proof');
      expect(parts.last.startsWith('pq'), isFalse,
          reason: 'disablePqAuth must suppress PQ challenge');

      final stored = (await ks.get('public:sess-dpa$bob'))?.data;
      expect(stored, isNotNull);
      expect(stored!.startsWith('pq:'), isFalse,
          reason: 'Stored secret must be plain UUID, not PQ confirmation tag');
    });

    test('self-auth (from: == currentAtSign) always uses legacy UUID', () async {
      final ks = keyStoreManager;

      final mockMgr = mockOcmServingPeerCert(null);
      final handler = FromVerbHandler(ks, mockMgr, accessLog: mockAccessLog);
      final atConnection =
          InboundConnectionImpl(mockSecureSocket, 'sess-004');

      final verbParams = HashMap<String, String?>();
      verbParams['atSign'] = alice.toString();

      final response = Response();
      await handler.processVerb(response, verbParams, atConnection);

      // Self: always data: prefix with UUID (no PQ)
      expect(response.data!.startsWith('data:'), isTrue);
      final parts = response.data!.split(':');
      expect(parts.last.startsWith('pq'), isFalse);
    });
  });
}

/// Builds an [OutboundClientManager] mock whose client live-`plookUp`s Bob's
/// published X-Wing cert JSON (or null, simulating a peer that publishes no
/// PQ cert) — the ML-DSA-65 public key travels embedded inside the cert
/// record, so a single lookup is the handshake's only source.
MockOutboundClientManager mockOcmServingPeerCert(String? certJson) {
  final mockOc = MockOutboundClient();
  when(() => mockOc.isConnectionCreated).thenReturn(true);
  when(() => mockOc.plookUp('pq_xwing_cert$bob'))
      .thenAnswer((_) async => certJson == null ? null : 'data:$certJson');
  final mockMgr = MockOutboundClientManager();
  when(() => mockMgr.getClient(any(), any(),
          handshakeRequired: any(named: 'handshakeRequired')))
      .thenAnswer((_) async => mockOc);
  return mockMgr;
}
