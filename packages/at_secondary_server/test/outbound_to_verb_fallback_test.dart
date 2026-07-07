import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/conf/config_util.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:yaml/yaml.dart';

import 'test_utils.dart';

/// Exercises [OutboundClient.checkRemotePublicKey]'s cross-server `to:` path
/// and its fallback to the legacy `lookup:all:publickey@peer` when a peer does
/// not understand `to:`. Driven through the shared harness (a single mock
/// outbound connection whose `write(...)` stubs feed `socketOnDataFn`).
void main() {
  final String toVerbRequest = 'to:$bob\n';
  final String legacyLookupRequest = 'lookup:all:publickey$bob\n';

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    // Restore the real yaml in case a test replaced it to flip the flag.
    AtSecondaryConfig.configYamlMap = ConfigUtil.getYaml();
    await verbTestsTearDown();
  });

  void enableOutboundToVerb() {
    AtSecondaryConfig.configYamlMap = YamlMap.wrap({
      'protocol': {'toVerbOutboundEnabled': true}
    });
  }

  /// A `{key, data, metaData}` entry in the shape a `lookup:all:` /  `to:`
  /// envelope carries, with a ttr:-1 public-key metadata like the real ones.
  Map publicKeyEntry(String keyName, String data) {
    DateTime now = DateTime.now().toUtcMillisecondsPrecision();
    var atData = AtData()
      ..data = data
      ..metaData = (AtMetaData()
        ..ttr = -1
        ..createdAt = now
        ..updatedAt = now);
    return jsonDecode(
        SecondaryUtil.prepareResponseData('all', atData, key: keyName)!);
  }

  group('to: outbound enabled', () {
    setUp(enableOutboundToVerb);

    test(
        'to: success caches the peer public key WITH its metadata and does'
        ' NOT fall back to the legacy lookup', () async {
      var envelope = jsonEncode({
        'publickey': publicKeyEntry('public:publickey$bob', 'BOB_ENC_KEY'),
        'signing_publickey':
            publicKeyEntry('public:signing_publickey$bob', 'BOB_SIGN_KEY'),
      });
      when(() => mockOutboundConnection.write(toVerbRequest))
          .thenAnswer((_) async {
        socketOnDataFn('data:$envelope\n$alice@'.codeUnits);
      });

      expect(
          await cacheManager.get(cachedBobsPublicKeyName,
              applyMetadataRules: true),
          isNull);
      await outboundClientWithoutHandshake.connect();

      var cached = (await cacheManager.get(cachedBobsPublicKeyName,
          applyMetadataRules: true))!;
      expect(cached.data, 'BOB_ENC_KEY');
      // The peer's metadata is carried through, not replaced by a bare
      // default — critically ttr:-1, so the cached public key is retained
      // rather than being subject to refresh. (An empty AtMetaData would
      // leave ttr null.)
      expect(cached.metaData!.ttr, -1);
      verify(() => mockOutboundConnection.write(toVerbRequest)).called(1);
      verifyNever(() => mockOutboundConnection.write(legacyLookupRequest));
    });

    test(
        'a peer that rejects to: with an error falls back to the legacy'
        ' lookup on the same connection', () async {
      when(() => mockOutboundConnection.write(toVerbRequest))
          .thenAnswer((_) async {
        socketOnDataFn(
            'error:AT0003-Exception: Received invalid verb that does not match'
                    ' protocol spec\n$alice@'
                .codeUnits);
      });
      when(() => mockOutboundConnection.write(legacyLookupRequest))
          .thenAnswer((_) async {
        socketOnDataFn('data:$bobOriginalPublicKeyAsJson\n$alice@'.codeUnits);
      });

      await outboundClientWithoutHandshake.connect();

      var cached = (await cacheManager.get(cachedBobsPublicKeyName,
          applyMetadataRules: true))!;
      expect(cached.data, bobOriginalPublicKeyAtData.data);
      verify(() => mockOutboundConnection.write(toVerbRequest)).called(1);
      verify(() => mockOutboundConnection.write(legacyLookupRequest)).called(1);
    });

    test(
        'a peer that CLOSES the connection on to: reconnects, then falls back'
        ' to the legacy lookup', () async {
      var factoryCalls = 0;
      when(() => mockOutboundConnectionFactory.createOutboundConnection(
          bobHost, bobPort, bob)).thenAnswer((_) async {
        factoryCalls++;
        // The reconnect hands back a fresh (reset) connection.
        mockOutboundConnection.metaData.isClosed = false;
        when(() => mockOutboundConnection.isInValid()).thenReturn(false);
        return mockOutboundConnection;
      });

      // The peer closes rather than replying: mark the connection closed so
      // read() bails out immediately instead of waiting out the timeout.
      when(() => mockOutboundConnection.write(toVerbRequest))
          .thenAnswer((_) async {
        mockOutboundConnection.metaData.isClosed = true;
        when(() => mockOutboundConnection.isInValid()).thenReturn(true);
      });
      when(() => mockOutboundConnection.write(legacyLookupRequest))
          .thenAnswer((_) async {
        socketOnDataFn('data:$bobOriginalPublicKeyAsJson\n$alice@'.codeUnits);
      });

      await outboundClientWithoutHandshake.connect();

      // One connection for the to: attempt, a second after the reconnect.
      expect(factoryCalls, 2);
      var cached = (await cacheManager.get(cachedBobsPublicKeyName,
          applyMetadataRules: true))!;
      expect(cached.data, bobOriginalPublicKeyAtData.data);
      verify(() => mockOutboundConnection.write(legacyLookupRequest)).called(1);
    });

    test(
        'an envelope reporting a null publickey is authoritative: no fallback,'
        ' cache untouched', () async {
      var envelope = jsonEncode({
        'publickey': null,
        'signing_publickey':
            publicKeyEntry('public:signing_publickey$bob', 'BOB_SIGN_KEY'),
      });
      when(() => mockOutboundConnection.write(toVerbRequest))
          .thenAnswer((_) async {
        socketOnDataFn('data:$envelope\n$alice@'.codeUnits);
      });

      await outboundClientWithoutHandshake.connect();

      expect(
          await cacheManager.get(cachedBobsPublicKeyName,
              applyMetadataRules: true),
          isNull);
      verify(() => mockOutboundConnection.write(toVerbRequest)).called(1);
      verifyNever(() => mockOutboundConnection.write(legacyLookupRequest));
    });
  });

  group('to: outbound disabled (default)', () {
    test('the legacy lookup is used and to: is never emitted', () async {
      when(() => mockOutboundConnection.write(legacyLookupRequest))
          .thenAnswer((_) async {
        socketOnDataFn('data:$bobOriginalPublicKeyAsJson\n$alice@'.codeUnits);
      });

      await outboundClientWithoutHandshake.connect();

      var cached = (await cacheManager.get(cachedBobsPublicKeyName,
          applyMetadataRules: true))!;
      expect(cached.data, bobOriginalPublicKeyAtData.data);
      verify(() => mockOutboundConnection.write(legacyLookupRequest)).called(1);
      verifyNever(() => mockOutboundConnection.write(toVerbRequest));
    });
  });
}
