import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

void main() {
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  group('A group of to verb tests', () {
    // The 'to:' verb is always understood. It is unauthenticated and must be
    // the first verb; each fresh connection is used for a single 'to:'
    // exchange.
    late OutboundConnectionFactory connection;

    setUp(() async {
      connection = OutboundConnectionFactory();
      await connection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
    });

    tearDown(() async {
      await connection.close();
    });

    test('to: for this server returns the {publickey, signing_publickey}'
        ' envelope in lookup:all: shape', () async {
      String response =
          await connection.sendRequestToServer('to:$firstAtSign');
      expect(response, startsWith('data:'));

      var envelope =
          jsonDecode(response.replaceFirst('data:', '').trim()) as Map;
      expect(envelope.keys, containsAll(['publickey', 'signing_publickey']));

      // The signing public key is generated at startup, so it is always
      // present and carries the {key, data, metaData} shape of a lookup:all:
      // response.
      var signingPublicKey = envelope['signing_publickey'] as Map;
      expect(signingPublicKey['key'], 'public:signing_publickey$firstAtSign');
      expect(signingPublicKey['data'], isNotNull);
      expect(signingPublicKey['metaData'], isA<Map>());

      // The encryption public key exists for an onboarded atSign, likewise in
      // {key, data, metaData} shape.
      var publicKey = envelope['publickey'] as Map;
      expect(publicKey['key'], 'public:publickey$firstAtSign');
      expect(publicKey['data'], isNotNull);
      expect(publicKey['metaData'], isA<Map>());
    });

    test('to: for another atSign is rejected (single-tenant)', () async {
      String response =
          await connection.sendRequestToServer('to:@some_other_atsign');
      expect(response, startsWith('error:'));
    });
  });
}
