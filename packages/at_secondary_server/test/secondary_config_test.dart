import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Parses an indented YAML literal, stripping the common leading whitespace so
/// it can be indented to match the surrounding code.
YamlMap _yaml(String indented) {
  final lines = indented.split('\n')
    ..removeWhere((line) => line.trim().isEmpty);
  final commonIndent = lines
      .map((line) => line.length - line.trimLeft().length)
      .reduce((a, b) => a < b ? a : b);
  return loadYaml(lines.map((line) => line.substring(commonIndent)).join('\n'));
}

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
      AtSecondaryConfig.configYamlMap = _yaml('''
        pq:
          disablePqAuth: true
      ''');
      expect(AtSecondaryConfig.disablePqAuth, isTrue);
    });

    test(
        'pq config falls back to hardcoded default when the yaml map is empty',
        () {
      AtSecondaryConfig.configYamlMap = _yaml('{}');
      expect(AtSecondaryConfig.disablePqAuth, isFalse);
    });

    test(
        'disablePqAuth: malformed yaml (list instead of bool) does not crash, '
        'falls back to default', () {
      AtSecondaryConfig.configYamlMap = _yaml('''
        pq:
          disablePqAuth:
            - true
      ''');
      expect(() => AtSecondaryConfig.disablePqAuth, returnsNormally);
      expect(AtSecondaryConfig.disablePqAuth, isFalse);
    });

    test(
        'protectedKeys: malformed yaml (scalar instead of list) does not crash, '
        'falls back to hardcoded defaults', () {
      AtSecondaryConfig.configYamlMap = _yaml('''
        hive:
          protectedKeys: not-a-list
      ''');
      expect(() => AtSecondaryConfig.protectedKeys, returnsNormally);
      expect(AtSecondaryConfig.protectedKeys, contains('publickey<@atsign>'));
    });

    test('protectedKeys: valid yaml list is merged with hardcoded defaults',
        () {
      AtSecondaryConfig.configYamlMap = _yaml('''
        hive:
          protectedKeys:
            - customkey
      ''');
      expect(AtSecondaryConfig.protectedKeys, contains('customkey'));
      expect(AtSecondaryConfig.protectedKeys, contains('publickey<@atsign>'));
    });

    test(
        'getNullableIntFromYaml/getNullableBoolFromYaml: malformed yaml '
        '(scalar intermediate) does not crash, returns null', () {
      AtSecondaryConfig.configYamlMap = _yaml('pq: true');
      expect(
          () => AtSecondaryConfig.getNullableIntFromYaml(
              ['pq', 'someIntSetting']),
          returnsNormally);
      expect(
          AtSecondaryConfig.getNullableIntFromYaml(
              ['pq', 'someIntSetting']),
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
