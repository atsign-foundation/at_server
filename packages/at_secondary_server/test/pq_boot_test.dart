import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'test_utils.dart';

/// Parses an indented YAML literal, stripping the common leading whitespace
/// first so the literal can be indented to match the surrounding code.
/// Mirrors the helper in secondary_config_test.dart.
YamlMap _yaml(String indented) {
  final lines = indented.split('\n')
    ..removeWhere((line) => line.trim().isEmpty);
  final commonIndent = lines
      .map((line) => line.length - line.trimLeft().length)
      .reduce((a, b) => a < b ? a : b);
  return loadYaml(lines.map((line) => line.substring(commonIndent)).join('\n'));
}

/// Covers [AtSecondaryServerImpl.initializePqAuth] — the PQ kill-switch and
/// init-failure boot logic. Extracted out of the private
/// `_initializePersistentInstances` specifically so it's testable without
/// booting a full server (see its doc comment); these are the one PQ code
/// path a fleet rollout most needs proven, since a stale published record
/// left behind by either branch would make peers keep sending a cookie
/// format this server can no longer parse.
void main() {
  final atSign = alice.toString();
  late YamlMap? originalYamlMap;

  setUpAll(() async {
    await verbTestsSetUpAll();
    registerFallbackValue(AtData());
  });

  setUp(() async {
    await verbTestsSetUp();
    originalYamlMap = AtSecondaryConfig.configYamlMap;
  });

  tearDown(() async {
    AtSecondaryConfig.configYamlMap = originalYamlMap;
    await verbTestsTearDown();
  });

  group('initializePqAuth — disablePqAuth kill switch', () {
    test('withdraws a previously-published PQ signing key when '
        'disablePqAuth is true', () async {
      // Seed a published record as if a prior boot (with PQ enabled) had
      // published one.
      await keyValueStore.put(pqSigningPublicKeyRecordName(atSign),
          AtData()..data = '{"$pqAlgoMlDsa65":"dummy"}');

      AtSecondaryConfig.configYamlMap = _yaml('''
        pq:
          disablePqAuth: true
      ''');

      await atServer.initializePqAuth(atSign, keyValueStore);

      expect(await keyValueStore.exists(pqSigningPublicKeyRecordName(atSign)),
          isFalse,
          reason: 'a peer must stop being able to fetch a record for a '
              'signature format this server no longer sends');
    });

    test(
        'is a no-op when disablePqAuth is true and no record was ever '
        'published', () async {
      AtSecondaryConfig.configYamlMap = _yaml('''
        pq:
          disablePqAuth: true
      ''');

      await expectLater(
          atServer.initializePqAuth(atSign, keyValueStore), completes);
      expect(await keyValueStore.exists(pqSigningPublicKeyRecordName(atSign)),
          isFalse);
    });
  });

  group('initializePqAuth — init failure', () {
    test('withdraws a previously-published PQ signing key when key '
        'initialisation throws', () async {
      await keyValueStore.put(pqSigningPublicKeyRecordName(atSign),
          AtData()..data = '{"$pqAlgoMlDsa65":"dummy"}');

      AtSecondaryConfig.configYamlMap = _yaml('{}'); // disablePqAuth: false

      final mockKeyStore = MockAtKeyValueStore();
      when(() => mockKeyStore.get(any()))
          .thenAnswer((_) async => null); // no existing key material
      when(() => mockKeyStore.put(any(), any())).thenThrow(
          Exception('simulated store fault while generating a keypair'));
      when(() => mockKeyStore.remove(pqSigningPublicKeyRecordName(atSign)))
          .thenAnswer((_) async {
        await keyValueStore.remove(pqSigningPublicKeyRecordName(atSign));
        return 1;
      });

      await atServer.initializePqAuth(atSign, mockKeyStore);

      verify(() => mockKeyStore.remove(pqSigningPublicKeyRecordName(atSign)))
          .called(1);
      expect(await keyValueStore.exists(pqSigningPublicKeyRecordName(atSign)),
          isFalse,
          reason: 'a server whose PQ keypair failed to initialise must not '
              'leave peers pointed at a record it can no longer sign for');
    });
  });
}
