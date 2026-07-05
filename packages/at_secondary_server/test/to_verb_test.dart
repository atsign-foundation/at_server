import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/to_verb_handler.dart';
import 'package:at_secondary/src/verb/to.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late MockAtKeyValueStore mockKeyStore;
  late FakeSocket mockSocket;
  const inBoundSessionId = '123';

  verbTestsSetUpLogging();

  setUp(() {
    mockKeyStore = MockAtKeyValueStore();
    mockSocket = FakeSocket();
  });

  group('to verb regex tests', () {
    test('to: with @', () {
      expect(getVerbParam(To().syntax(), 'to:@alice')['atSign'], '@alice');
    });

    test('to: without @', () {
      expect(getVerbParam(To().syntax(), 'to:alice')['atSign'], 'alice');
    });

    test('to: with emoji', () {
      expect(getVerbParam(To().syntax(), 'to:@🦄')['atSign'], '@🦄');
    });

    test('to: is an unauthenticated verb named "to"', () {
      expect(To().requiresAuth(), false);
      expect(To().name(), 'to');
    });
  });

  group('to verb accept tests', () {
    // Inbound understanding of to: is always on — it is unauthenticated and
    // serves only data that is already publicly readable via lookup:.
    test('to: is accepted', () {
      expect(ToVerbHandler(mockKeyStore).accept('to:@alice'), true);
    });

    test('a non-to: command is never accepted', () {
      expect(ToVerbHandler(mockKeyStore).accept('from:@alice'), false);
    });
  });

  group('to verb processVerb tests', () {
    // Stored AtData always carries metadata (createdAt/updatedAt are set by
    // AtMetadataBuilder on every put); the envelope must preserve it.
    AtData atDataWith(String data) => AtData()
      ..data = data
      ..metaData = (AtMetaData()
        ..createdBy = alice
        ..createdAt = DateTime.utc(2026, 1, 2, 3, 4, 5)
        ..updatedAt = DateTime.utc(2026, 1, 2, 3, 4, 5)
        ..ttl = 86400);

    void stubKeys({String? enc, String? sign}) {
      when(() => mockKeyStore.get(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments[0] as String;
        if (key == 'public:publickey@alice') {
          return enc == null ? null : atDataWith(enc);
        }
        if (key == 'public:signing_publickey@alice') {
          return sign == null ? null : atDataWith(sign);
        }
        return null;
      });
    }

    test(
        'returns the {publickey, signing_publickey} envelope, each value in'
        ' lookup:all: {key, data, metaData} shape', () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      stubKeys(enc: 'ENC_PUBLIC_KEY', sign: 'SIGNING_PUBLIC_KEY');

      var verbParams = getVerbParam(To().syntax(), 'to:@alice');
      var conn = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var response = Response();
      await ToVerbHandler(mockKeyStore).processVerb(response, verbParams, conn);

      var envelope = jsonDecode(response.data!) as Map;
      var publicKey = envelope['publickey'] as Map;
      expect(publicKey['key'], 'public:publickey@alice');
      expect(publicKey['data'], 'ENC_PUBLIC_KEY');
      expect(publicKey['metaData']['createdBy'], alice);
      expect(publicKey['metaData']['ttl'], 86400);
      var signingKey = envelope['signing_publickey'] as Map;
      expect(signingKey['key'], 'public:signing_publickey@alice');
      expect(signingKey['data'], 'SIGNING_PUBLIC_KEY');
      expect(signingKey['metaData']['ttl'], 86400);
      expect((conn.metaData as InboundConnectionMetadata).toAtSign, alice);

      // The value round-trips through AtData().fromJson — which is what
      // OutboundClient does with it — preserving the peer's metadata.
      var roundTripped = AtData().fromJson(publicKey);
      expect(roundTripped.data, 'ENC_PUBLIC_KEY');
      expect(roundTripped.metaData!.ttl, 86400);
      expect(roundTripped.metaData!.createdBy, alice);
    });

    test('a null encryption public key surfaces as null in the envelope',
        () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      stubKeys(enc: null, sign: 'SIGNING_PUBLIC_KEY');

      var verbParams = getVerbParam(To().syntax(), 'to:@alice');
      var conn = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var response = Response();
      await ToVerbHandler(mockKeyStore).processVerb(response, verbParams, conn);

      var envelope = jsonDecode(response.data!) as Map;
      expect(envelope['publickey'], isNull);
      expect(envelope['signing_publickey']['data'], 'SIGNING_PUBLIC_KEY');
    });

    test('a to: for another atSign is rejected (single-tenant)', () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      var verbParams = getVerbParam(To().syntax(), 'to:@bob');
      var conn = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var response = Response();
      await expectLater(
          ToVerbHandler(mockKeyStore).processVerb(response, verbParams, conn),
          throwsA(isA<SecondaryNotFoundException>()));
    });
  });
}
