import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

void main() async {
  group('A group of secondary config test', () {
    test('Config: Check rootServerUrl is a String', () async {
      expect(AtSecondaryConfig.rootServerUrl.isNotEmpty, true);
    });

    test('Config: check rootServerPort is an int', () async {
      expect(AtSecondaryConfig.rootServerPort > 0, true);
    });

    test('Config: check AtSecondaryConfig.logLevel defaults to FINEST',
        () async {
      expect(AtSecondaryConfig.logLevel.trim().toUpperCase(),
          equals(logging.Level.INFO.name.trim().toUpperCase()));
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
