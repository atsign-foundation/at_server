import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:test/test.dart';

void main() {
  group('group of command conversion test', () {
    test('convert command', () {
      var result = SecondaryUtil.convertCommand('update:privateKey:abc HelLo');
      print(result);
    });
  });
}