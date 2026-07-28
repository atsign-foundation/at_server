import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/crypto/pq_key_manager.dart';
import 'package:at_secondary/src/crypto/pq_signing_public_record.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// A well-formed published record, as a peer running PQ code would serve it.
/// The key bytes are arbitrary — `checkPeerPqSupport` only needs the record to
/// parse and carry an entry for the algorithm, not to be a usable key.
final String _validPeerRecord = 'data:'
    '${buildPqSigningPublicRecord({
      pqAlgoMlDsa65: Uint8List.fromList(List<int>.filled(8, 7))
    })}';

/// Stubs the wire-level [plookUp] so [OutboundClient.checkPeerPqSupport] and
/// [OutboundClient.selectAndSignChallenge] can be tested without a live
/// socket — everything else on [OutboundClient] is exercised as-is.
class _StubOutboundClient extends OutboundClient {
  final Future<String?> Function(String key) plookUpStub;

  _StubOutboundClient(
    super.inboundConnection,
    super.toAtSign,
    super.secondaryAddressFinder,
    super.handshakeRequired,
    super.outboundConnectionFactory,
    super.pqKeyManager,
    this.plookUpStub,
  );

  @override
  Future<String?> plookUp(String key) => plookUpStub(key);
}

void main() {
  late FakeSocket mockSocket;
  OutboundConnectionFactory outboundConnectionFactory =
      DefaultOutboundConnectionFactory(clientCertificateRequired: false);

  verbTestsSetUpLogging();
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  _StubOutboundClient makeClient(Future<String?> Function(String) plookUpStub,
      {PqKeyManager? pqKeyManager}) {
    mockSocket = FakeSocket();
    var inbound = InboundConnectionImpl(mockSocket, 'test-session');
    return _StubOutboundClient(
      inbound,
      bob,
      AtSecondaryServerImpl.getInstance().secondaryAddressFinder,
      true,
      outboundConnectionFactory,
      pqKeyManager ?? AtSecondaryServerImpl.getInstance().pqKeyManager,
      plookUpStub,
    );
  }

  group('OutboundClient.checkPeerPqSupport', () {
    test('true when the peer has published a PQ signing key record', () async {
      final oc = makeClient((key) async => _validPeerRecord);
      expect(await oc.checkPeerPqSupport(), isTrue);
    });

    test('false when the peer has no PQ signing key record', () async {
      final oc = makeClient((key) async {
        throw KeyNotFoundException('key not found : $key');
      });
      expect(await oc.checkPeerPqSupport(), isFalse);
    });

    test('false (fail-safe) on any other lookup failure', () async {
      final oc = makeClient((key) async {
        throw AtTimeoutException('no response');
      });
      expect(await oc.checkPeerPqSupport(), isFalse);
    });

    test('probes the peer-specific PQ record name', () async {
      String? probedKey;
      final oc = makeClient((key) async {
        probedKey = key;
        return _validPeerRecord;
      });
      await oc.checkPeerPqSupport();
      expect(probedKey, equals('$pqSigningPublicKeyRecordNamePart$bob'));
    });

    test('false when the peer record carries no ml-dsa-65 entry', () async {
      final oc = makeClient((key) async => 'data:'
          '${buildPqSigningPublicRecord({
                'some-future-algo': Uint8List.fromList([1, 2, 3])
              })}');
      expect(await oc.checkPeerPqSupport(), isFalse,
          reason: 'signing a cookie the peer cannot verify is worse than '
              'falling back to RSA');
    });

    test('false when the peer record is unparseable', () async {
      final oc = makeClient((key) async => 'data:not-json');
      expect(await oc.checkPeerPqSupport(), isFalse);
    });

    test('false when the lookup returns nothing', () async {
      final oc = makeClient((key) async => null);
      expect(await oc.checkPeerPqSupport(), isFalse);
    });
  });

  group('OutboundClient.selectAndSignChallenge', () {
    late PqKeyManager initialisedPqKeyManager;

    setUp(() async {
      initialisedPqKeyManager = PqKeyManager();
      await initialisedPqKeyManager.init(alice.toString(), keyValueStore);
    });

    test('PQ key initialised + peer supports PQ → ML-DSA cookie', () async {
      final oc = makeClient((key) async => _validPeerRecord,
          pqKeyManager: initialisedPqKeyManager);
      final cookie = await oc.selectAndSignChallenge('a-challenge');
      expect(cookie, startsWith('pq:$pqAlgoMlDsa65:'));
    });

    test(
        'PQ key initialised but peer does NOT support PQ → legacy RSA cookie (backward compat)',
        () async {
      final oc = makeClient((key) async {
        throw KeyNotFoundException('key not found : $key');
      }, pqKeyManager: initialisedPqKeyManager);
      final cookie = await oc.selectAndSignChallenge('a-challenge');
      expect(cookie, isNot(startsWith('pq:')));
    });

    test('PQ key not initialised → legacy RSA cookie regardless of peer',
        () async {
      final oc = makeClient((key) async => _validPeerRecord);
      final cookie = await oc.selectAndSignChallenge('a-challenge');
      expect(cookie, isNot(startsWith('pq:')));
    });

    test('PQ and RSA both sign the same challenge bytes', () async {
      const challenge = 'the-bound-challenge';

      final pqCookie = await makeClient((key) async => _validPeerRecord,
              pqKeyManager: initialisedPqKeyManager)
          .selectAndSignChallenge(challenge);
      final pqSig = base64.decode(pqCookie.split(':')[2]);
      final pub = initialisedPqKeyManager.mlDsaPublicKey;

      expect(
          await AtPqc.mlDsa65.verifyBytes(utf8.encode(challenge),
              signature: pqSig, publicKey: pub),
          isTrue);

      final rsaCookie = await makeClient((key) async {
        throw KeyNotFoundException('key not found : $key');
      }, pqKeyManager: initialisedPqKeyManager)
          .selectAndSignChallenge(challenge);
      expect(
          rsaCookie,
          equals(SecondaryUtil.signChallenge(
              challenge, AtSecondaryServerImpl.getInstance().signingKey)),
          reason: 'the RSA path must sign the challenge verbatim, exactly as '
              'every deployed at_server already does');
    });
  });
}
