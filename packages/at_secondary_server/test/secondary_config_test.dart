import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() async {
  group('A group of secondary config test', () {
    test('Config: Check rootServerUrl is a String', () async {
      expect(AtSecondaryConfig.rootServerUrl.isNotEmpty, true);
    });

    test('Config: check rootServerPort is an int', () async {
      expect(AtSecondaryConfig.rootServerPort > 0, true);
    });

    test('Config: check AtSecondaryConfig.logLevel defaults to INFO', () async {
      expect(AtSecondaryConfig.logLevel.trim().toUpperCase(),
          equals(logging.Level.INFO.name.trim().toUpperCase()));
    });

    test('Config: toVerbOutboundEnabled defaults to false (fleet-safe)',
        () async {
      expect(AtSecondaryConfig.toVerbOutboundEnabled, false);
    });

    test('Config: testingMode is false by default', () async {
      expect(AtSecondaryConfig.testingMode, isFalse,
          reason: 'testingMode relaxes rules that protect the atSign, so the '
              'shipped configuration must not enable it');
    });

    test('Config: testingMode with no yaml at all is false, not unknown',
        () async {
      final YamlMap? saved = AtSecondaryConfig.configYamlMap;
      addTearDown(() => AtSecondaryConfig.configYamlMap = saved);
      AtSecondaryConfig.configYamlMap = null;
      expect(AtSecondaryConfig.testingMode, isFalse,
          reason: 'a server that cannot read its config must not be a server '
              'with testingMode on');
    });

    test('Config: testingMode is read from testing.testingMode', () async {
      final YamlMap? saved = AtSecondaryConfig.configYamlMap;
      addTearDown(() => AtSecondaryConfig.configYamlMap = saved);
      // The yaml path is pinned by a TRUE case: false is also what every
      // failure to find the setting returns, so a getter reading the wrong
      // key would pass the default-false test above.
      AtSecondaryConfig.configYamlMap =
          loadYaml('testing:\n  testingMode: true') as YamlMap;
      expect(AtSecondaryConfig.testingMode, isTrue,
          reason: 'testingMode is the `testingMode` entry of the `testing` '
              'block, which is what the rigs and the shipped config.yaml set');
    });

    test(
        'Config: check new AtSignLoggers have level set correctly, via setting AtSignLogger.root_level from a string config setting',
        () async {
      AtSignLogger.root_level = 'wARNinG';
      AtSignLogger atLogger = AtSignLogger('test');
      expect(atLogger.logger.level, equals(logging.Level.WARNING));
    });
  });
}
