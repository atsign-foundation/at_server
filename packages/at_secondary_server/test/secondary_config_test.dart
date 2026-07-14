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

    test(
        'Config: check new AtSignLoggers have level set correctly, via setting AtSignLogger.root_level from a string config setting',
        () async {
      AtSignLogger.root_level = 'wARNinG';
      AtSignLogger atLogger = AtSignLogger('test');
      expect(atLogger.logger.level, equals(logging.Level.WARNING));
    });
  });

  group('yaml-driven config precedence and robustness', () {
    YamlMap? originalYamlMap;

    setUp(() {
      originalYamlMap = AtSecondaryConfig.configYamlMap;
    });

    tearDown(() {
      AtSecondaryConfig.configYamlMap = originalYamlMap;
    });

    test('disablePqAuth: yaml value used when no env var is set', () {
      AtSecondaryConfig.configYamlMap = loadYaml('''
pq:
  disablePqAuth: true
''');
      expect(AtSecondaryConfig.disablePqAuth, isTrue);
    });

    test('xwingCertExpiryInDays: yaml value used when no env var is set', () {
      AtSecondaryConfig.configYamlMap = loadYaml('''
pq:
  xwingCertExpiryInDays: 45
''');
      expect(AtSecondaryConfig.xwingCertExpiryInDays, equals(45));
    });

    test('certRenewalHeadroomDays: yaml value used when no env var is set', () {
      AtSecondaryConfig.configYamlMap = loadYaml('''
pq:
  certRenewalHeadroomDays: 7
''');
      expect(AtSecondaryConfig.certRenewalHeadroomDays, equals(7));
    });

    test(
        'disablePqAuth/xwingCertExpiryInDays/certRenewalHeadroomDays fall back '
        'to hardcoded defaults when the yaml map is empty', () {
      AtSecondaryConfig.configYamlMap = loadYaml('{}');
      expect(AtSecondaryConfig.disablePqAuth, isFalse);
      expect(AtSecondaryConfig.xwingCertExpiryInDays, equals(90));
      expect(AtSecondaryConfig.certRenewalHeadroomDays, equals(30));
    });

    test('xwingCertExpiryInDays: non-positive yaml value falls back to default',
        () {
      AtSecondaryConfig.configYamlMap = loadYaml('''
pq:
  xwingCertExpiryInDays: 0
''');
      expect(AtSecondaryConfig.xwingCertExpiryInDays, equals(90));
    });

    test(
        'protectedKeys: malformed yaml (scalar instead of list) does not crash, '
        'falls back to hardcoded defaults', () {
      AtSecondaryConfig.configYamlMap = loadYaml('''
hive:
  protectedKeys: not-a-list
''');
      expect(() => AtSecondaryConfig.protectedKeys, returnsNormally);
      expect(AtSecondaryConfig.protectedKeys, contains('publickey<@atsign>'));
    });

    test(
        'getNullableIntFromYaml/getNullableBoolFromYaml: malformed yaml '
        '(scalar intermediate) does not crash, returns null', () {
      AtSecondaryConfig.configYamlMap = loadYaml('''
pq: true
''');
      expect(
          () => AtSecondaryConfig.getNullableIntFromYaml(
              ['pq', 'xwingCertExpiryInDays']),
          returnsNormally);
      expect(
          AtSecondaryConfig.getNullableIntFromYaml(
              ['pq', 'xwingCertExpiryInDays']),
          isNull);
      expect(
          () => AtSecondaryConfig.getNullableBoolFromYaml(
              ['pq', 'disablePqAuth']),
          returnsNormally);
      expect(AtSecondaryConfig.getNullableBoolFromYaml(['pq', 'disablePqAuth']),
          isNull);
    });
  });
}
