import 'dart:io';

import 'package:at_root_server/at_root_server.dart';
import 'package:test/test.dart';

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

    test('with useSSL false', () {
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
      expect(c.securityContext, isNull);
    });
  });
}
