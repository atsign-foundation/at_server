import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:test/test.dart';

void main() {
  group('group of command conversion test', () {
    test('convert command', () {
      final i = 'update:privateKey:abc HelLo';
      final o = SecondaryUtil.convertCommand(i);
      expect(o, i);
    });
  });
}
