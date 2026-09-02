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

    test('Config: legacyCredentialRetirementHours defaults to 30 days',
        () async {
      // A RAW literal, not the constant that defines it. This is how long
      // every deployed atSign holding a flat PKAM credential keeps it after
      // its owner starts minting enrollments, so a change to it is a change
      // to what operators were told, and editing this line is the review.
      expect(AtSecondaryConfig.legacyCredentialRetirementHours, 720,
          reason: 'the migration window is 30 days');
    });

    test('Config: legacyCredentialRetirementHours is its own setting', () {
      // Deliberately NOT apkamSelfEnrollmentGraceHours, which happens to
      // carry the same default. One is how long a superseded shared keyfile
      // stays usable so laggard siblings can split off it; this is how long a
      // flat credential survives its owner moving to enrollments. Shared,
      // an operator shortening the first would silently shorten the second.
      expect(AtSecondaryConfig.legacyCredentialRetirementHours,
          AtSecondaryConfig.apkamSelfEnrollmentGraceHours,
          reason: 'they coincide TODAY, which is exactly what makes it '
              'tempting to fold them together');
      final YamlMap? saved = AtSecondaryConfig.configYamlMap;
      addTearDown(() => AtSecondaryConfig.configYamlMap = saved);
      AtSecondaryConfig.configYamlMap =
          loadYaml('enrollment:\n  apkamSelfEnrollmentGraceHours: 24')
              as YamlMap;
      expect(AtSecondaryConfig.apkamSelfEnrollmentGraceHours, 24,
          reason: 'precondition: the retrofit grace was shortened');
      expect(AtSecondaryConfig.legacyCredentialRetirementHours, 720,
          reason: 'and every atSign on the server still has its full '
              'migration window');
    });

    test('Config: legacyCredentialRetirementHours is not settable at runtime',
        () {
      // config:set resolves its name through ModifiableConfigs.values.byName,
      // so a setting absent from that enum has no runtime path at all. It
      // stays absent: shortening the window on a live server would retire
      // credentials the operator did not intend to, and there is no verb that
      // puts one back.
      expect(
          ModifiableConfigs.values
              .any((c) => c.name == 'legacyCredentialRetirementHours'),
          isFalse,
          reason: 'the migration window is a deployment decision, not a live '
              'one — a removal it triggers cannot be undone');
      expect(
          ModifiableConfigs.values.any((c) => c.name == 'inboundMaxLimit'),
          isTrue,
          reason: 'CONTROL: the enum does carry settings, so the absence '
              'above is about this one');
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
