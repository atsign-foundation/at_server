import 'package:at_secondary/src/gate/gate_store.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../test_utils.dart';

/// The operator's gate limits, read from the `gate` section of the config.
void main() {
  const GateLimits builtIn = GateLimits();

  late YamlMap? shipped;

  setUpAll(() => shipped = AtSecondaryConfig.configYamlMap);

  tearDown(() => AtSecondaryConfig.configYamlMap = shipped);

  void configure(String yaml) =>
      AtSecondaryConfig.configYamlMap = loadYaml(yaml) as YamlMap;

  // Every value differs from its built-in one, so a value read from the wrong
  // path shows as the built-in value.
  const String everyValueChanged = '''
gate:
  quarantine:
    limit: {default: 11, max: 101, min: 2}
    window: {default: 7200, max: 172800, min: 1800}
    size: {default: 1000, max: 2000, min: 10}
    maxQuarantined: {default: 7, max: 8, min: 3}
    maxQuarantinedBytes: {default: 5000, max: 6000, min: 4}
  maxOpenNamespaces: 51
  maxQuarantinedBytesEverywhere: 1001
  maxNamespaces: 1002
  maxAdmitted: 1003
  maxDenied: 1004
  maxAdmittedEverywhere: 1005
''';

  group('Given a gate section setting every value', () {
    test('when the limits are read, then each comes from its own path', () {
      configure(everyValueChanged);
      final GateLimits limits = AtSecondaryConfig.gateLimits;
      expect(limits.defaults, {
        GateSetting.limit: 11,
        GateSetting.window: 7200,
        GateSetting.size: 1000,
        GateSetting.maxQuarantined: 7,
        GateSetting.maxQuarantinedBytes: 5000,
      });
      expect(limits.ceilings, {
        GateSetting.limit: 101,
        GateSetting.window: 172800,
        GateSetting.size: 2000,
        GateSetting.maxQuarantined: 8,
        GateSetting.maxQuarantinedBytes: 6000,
      });
      expect(limits.floors, {
        GateSetting.limit: 2,
        GateSetting.window: 1800,
        GateSetting.size: 10,
        GateSetting.maxQuarantined: 3,
        GateSetting.maxQuarantinedBytes: 4,
      });
      expect(
          [
            limits.maxOpenNamespaces,
            limits.maxQuarantinedBytesEverywhere,
            limits.maxNamespaces,
            limits.maxAdmitted,
            limits.maxDenied,
            limits.maxAdmittedEverywhere,
          ],
          [51, 1001, 1002, 1003, 1004, 1005]);
    });

    test('when the atServer loads its gate, then the gate has those limits',
        () async {
      await verbTestsSetUpAll();
      await verbTestsSetUp();
      addTearDown(verbTestsTearDown);
      configure(everyValueChanged);
      final Gatekeeper gate = await AtSecondaryServerImpl.loadGatekeeper(
          GateStore(keyValueStore, alice));
      expect(gate.limits.maxOpenNamespaces, 51);
      expect(gate.limits.defaults[GateSetting.limit], 11);
    });
  });

  test('Given no gate section, when the limits are read, then they are the'
      ' built-in ones', () {
    AtSecondaryConfig.configYamlMap = YamlMap.wrap({});
    final GateLimits limits = AtSecondaryConfig.gateLimits;
    expect(limits.defaults, builtIn.defaults);
    expect(limits.ceilings, builtIn.ceilings);
    expect(limits.floors, builtIn.floors);
    expect(limits.maxOpenNamespaces, builtIn.maxOpenNamespaces);
    expect(limits.maxQuarantinedBytesEverywhere,
        builtIn.maxQuarantinedBytesEverywhere);
  });

  test('Given the shipped config, then its gate section states the built-in'
      ' values', () {
    final YamlMap gate = shipped!['gate'] as YamlMap;
    final YamlMap quarantine = gate['quarantine'] as YamlMap;
    for (final GateSetting setting in GateSetting.values) {
      final YamlMap values = quarantine[setting.name] as YamlMap;
      expect(values['default'], builtIn.defaults[setting], reason: setting.name);
      expect(values['max'], builtIn.ceilings[setting], reason: setting.name);
      if (values.containsKey('min')) {
        expect(values['min'], builtIn.floors[setting], reason: setting.name);
      }
    }
    expect(gate['maxOpenNamespaces'], builtIn.maxOpenNamespaces);
    expect(gate['maxQuarantinedBytesEverywhere'],
        builtIn.maxQuarantinedBytesEverywhere);
    expect(gate['maxNamespaces'], builtIn.maxNamespaces);
    expect(gate['maxAdmitted'], builtIn.maxAdmitted);
    expect(gate['maxDenied'], builtIn.maxDenied);
    expect(gate['maxAdmittedEverywhere'], builtIn.maxAdmittedEverywhere);
  });

  group('Given a default outside its bounds', () {
    for (final (String bounds, String yaml) in [
      ('a limit above its max', 'limit: {default: 101}'),
      ('a window below its min', 'window: {default: 60}'),
      ('a size whose max is below it', 'size: {max: 1000}'),
    ]) {
      test('when the limits are read with $bounds, then they are refused', () {
        configure('gate:\n  quarantine:\n    $yaml');
        expect(() => AtSecondaryConfig.gateLimits, throwsArgumentError);
      });
    }
  });

  test('The environment variables are named after their paths', () {
    // NOTE operators set these by name, so the names are pinned as written.
    expect(
        [
          AtSecondaryConfig.gateEnvVar('limit', 'default'),
          AtSecondaryConfig.gateEnvVar('window', 'min'),
          AtSecondaryConfig.gateEnvVar('maxQuarantinedBytes', 'max'),
          AtSecondaryConfig.gateEnvVar('maxOpenNamespaces'),
          AtSecondaryConfig.gateEnvVar('maxQuarantinedBytesEverywhere'),
        ],
        [
          'gateLimitDefault',
          'gateWindowMin',
          'gateMaxQuarantinedBytesMax',
          'gateMaxOpenNamespaces',
          'gateMaxQuarantinedBytesEverywhere',
        ]);
  });
}
