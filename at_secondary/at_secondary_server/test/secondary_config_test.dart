import 'package:test/test.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';

void main() async {
  group('A group of secondary config test', () {
    test('get String value', () async {
      expect(AtSecondaryConfig.rootServerUrl is String, true);
    });

    test('get int value', () async {
      expect(AtSecondaryConfig.rootServerPort is int, true);
    });

    test('get bool value', () async {
      expect(AtSecondaryConfig.debugLog is bool, true);
    });
  });
}
