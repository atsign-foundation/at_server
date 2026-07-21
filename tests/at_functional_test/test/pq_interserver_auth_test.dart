import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

/// End-to-end cover for the post-quantum inter-server handshake.
///
/// The unit tests around `PolVerbHandler` stub every `lookUp`/`plookUp`, so
/// they cannot show that the published PQ signing record is actually reachable
/// over the wire. It is written straight to the keystore by `PqKeyManager`
/// with no `AtMetaData`, and served through the ordinary plookup path — if
/// that combination did not resolve, every unit test would still pass while
/// inter-server auth was broken in production.
void main() {
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  const String pqRecordName = 'pq_signing_publickey';
  const String pqAlgo = 'ml-dsa-65';

  late OutboundConnectionFactory connection;

  setUp(() async {
    connection = OutboundConnectionFactory();
    await connection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  tearDown(() async => await connection.close());

  group('PQ signing public key is published and peer-fetchable', () {
    test('plookup returns a parseable record carrying an $pqAlgo key',
        () async {
      String response = await connection
          .sendRequestToServer('plookup:$pqRecordName$firstAtSign');
      expect(response, startsWith('data:'),
          reason: 'the record is published at startup by PqKeyManager, so an '
              'unauthenticated plookup must resolve it — a peer performing pol '
              'fetches it exactly this way');

      var record = jsonDecode(response.replaceFirst('data:', '').trim()) as Map;
      expect(record.keys, contains(pqAlgo),
          reason: 'the record is keyed by algorithm id for crypto agility');
      expect(base64Decode(record[pqAlgo] as String).length, 1952,
          reason: 'raw ML-DSA-65 public key length (FIPS 204)');
    });

    test('the same record is reachable on the peer atSign', () async {
      String response = await connection
          .sendRequestToServer('plookup:$pqRecordName$secondAtSign');
      expect(response, startsWith('data:'),
          reason: 'cross-server pol depends on fetching the *peer\'s* record');

      var record = jsonDecode(response.replaceFirst('data:', '').trim()) as Map;
      expect(record.keys, contains(pqAlgo));
    });
  });

  group('PQ record is protected from clients', () {
    setUp(() async => await connection.authenticateConnection());

    test('an authenticated client cannot update it', () async {
      String response = await connection.sendRequestToServer(
          'update:public:$pqRecordName$firstAtSign forged');
      expect(response, startsWith('error:'),
          reason: 'only the server may write its own signing key');
    });

    test('an authenticated client cannot delete it', () async {
      String response = await connection
          .sendRequestToServer('delete:public:$pqRecordName$firstAtSign');
      expect(response, startsWith('error:'));
    });
  });

  group('cross-server auth completes with PQ in play', () {
    setUp(() async => await connection.authenticateConnection());

    test('a lookup of a key shared by the peer completes a FROM/POL handshake',
        () async {
      // Forces this server to open an outbound connection to the peer and run
      // the full FROM/POL exchange. Both servers publish a PQ record, so the
      // handshake takes the ML-DSA path; a signature or record failure would
      // surface here as an error response rather than data/no-key.
      String response = await connection
          .sendRequestToServer('lookup:shared_key$secondAtSign');
      expect(response, anyOf(startsWith('data:'), startsWith('error:AT0015')),
          reason: 'either the key resolves or it genuinely does not exist; an '
              'auth failure would come back as a pol/handshake error');
    });
  });
}
