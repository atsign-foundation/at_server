import 'dart:io';

import 'package:at_root_server/at_root_server.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  // Command-line arg parsing is tested in at_args_parser_test.dart
  // We will use these args, since context creation requires them
  final redisHost = 'redis_host';
  final redisPort = 6379;
  final redisAuth = 'redis_password';
  final args = [
    '--redis_host',
    redisHost,
    '--redis_port',
    redisPort.toString(),
    '--redis_auth',
    redisAuth,
  ];

  setUp(() {
    AtRootConfig.envVars = Platform.environment;
    AtRootConfig.yaml = ConfigUtil.getYaml();
  });

  group('context creation', () {
    test('static createAtRootServerContext', () {
      final c = RootServerBootStrapper.createAtRootServerContext(args);
      expect(c.redisServerHost, redisHost);
      expect(c.redisServerPort, redisPort);
      expect(c.redisAuth, redisAuth);

      expect(c.port, AtRootConfig.rootServerPort);
      expect(c.httpsPort, AtRootConfig.httpsPort);
      expect(c.httpsEnabled, AtRootConfig.httpsEnabled);

      expect(c.securityContext, isNotNull);
      expect(c.securityContext!.publicKeyPath(),
          AtRootConfig.certificateChainLocation);
      expect(
          c.securityContext!.privateKeyPath(), AtRootConfig.privateKeyLocation);
    });

    test('createAtRootServerContext called by constructor', () {
      final boot = RootServerBootStrapper(args);
      final c = RootServerBootStrapper.createAtRootServerContext(args);
      expect(c, boot.rootContext);
    });

    test('with overrides to AtRootConfig from environment', () {
      expect(AtRootConfig.envVars, Platform.environment);

      final Map<String, String> testEnv = {
        'certificateChainLocation': '/foo/bar/fullchain.pem',
        'privateKeyLocation': '/foo/bar/privatekey.pem',
        'rootServerPort': '4064',
        'httpsPort': '4443',
        'httpsEnabled': '${!AtRootConfig.httpsEnabled}',
      };
      AtRootConfig.envVars = testEnv;

      final boot = RootServerBootStrapper(args);
      final c = RootServerBootStrapper.createAtRootServerContext(args);
      expect(c, boot.rootContext);

      expect(c.securityContext!.publicKeyPath(),
          testEnv['certificateChainLocation']);
      expect(
          c.securityContext!.privateKeyPath(), testEnv['privateKeyLocation']);
      expect(c.port, int.tryParse(testEnv['rootServerPort'].toString()));
      expect(c.httpsPort, int.tryParse(testEnv['httpsPort'].toString()));
      expect(c.httpsEnabled.toString(), testEnv['httpsEnabled']);
    });

    test('with useSSL false from environment', () {
      expect(AtRootConfig.envVars, Platform.environment);

      final Map<String, String> testEnv = {
        'useSSL': 'false',
      };
      AtRootConfig.envVars = testEnv;

      final boot = RootServerBootStrapper(args);
      final c = RootServerBootStrapper.createAtRootServerContext(args);
      expect(c, boot.rootContext);

      expect(c.port, AtRootConfig.rootServerPort);
      expect(c.httpsPort, AtRootConfig.httpsPort);
      expect(c.httpsEnabled, AtRootConfig.httpsEnabled);

      // useSSL == false results in this
      expect(c.securityContext, isNull);
    });

    test('with overrides to AtRootConfig from YAML', () {
      expect(AtRootConfig.yaml, ConfigUtil.getYaml());

      YamlMap testYaml = loadYaml(''
          'server:\n'
          '  port: 4064\n'
          '  httpsPort: 4443\n'
          '  httpsEnabled: false\n'
          'security:\n'
          '  useSSL: true\n'
          '  certificateChainLocation: \'/foo/bar/fullchain.pem\'\n'
          '  privateKeyLocation: \'/foo/bar/privatekey.pem\'\n');

      AtRootConfig.yaml = testYaml;

      final boot = RootServerBootStrapper(args);
      final c = RootServerBootStrapper.createAtRootServerContext(args);
      expect(c, boot.rootContext);

      expect(c.securityContext!.publicKeyPath(),
          testYaml['security']['certificateChainLocation']);
      expect(c.securityContext!.privateKeyPath(),
          testYaml['security']['privateKeyLocation']);
      expect(c.port, testYaml['server']['port']);
      expect(c.httpsPort, testYaml['server']['httpsPort']);
      expect(c.httpsEnabled, testYaml['server']['httpsEnabled']);
    });

    test('with useSSL false from YAML', () {
      expect(AtRootConfig.yaml, ConfigUtil.getYaml());

      YamlMap testYaml = loadYaml(''
          'security:\n'
          '  useSSL: false\n');

      AtRootConfig.yaml = testYaml;

      final boot = RootServerBootStrapper(args);
      final c = RootServerBootStrapper.createAtRootServerContext(args);
      expect(c, boot.rootContext);

      expect(c.port, AtRootConfig.rootServerPort);
      expect(c.httpsPort, AtRootConfig.httpsPort);
      expect(c.httpsEnabled, AtRootConfig.httpsEnabled);

      // useSSL == false results in this
      expect(c.securityContext, isNull);
    });
  });
}
