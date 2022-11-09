import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:test/test.dart';

void main() {
  group('group of command conversion test', () {
    test('convert command with value', () {
      var result = SecondaryUtil.convertCommand('update:privateKey:abc HelLo');
      print(result);
      expect(result, 'update:privatekey:abc HelLo');
    });

    test('convert command with value - verb has upper case', () {
      var result = SecondaryUtil.convertCommand('UpdAte:Phone:aBc HelLo');
      print(result);
      expect(result, 'update:phone:abc HelLo');
    });

    test('convert command without value', () {
      var result = SecondaryUtil.convertCommand('delEte:privateKey:aBc');
      print(result);
      expect(result, 'delete:privatekey:abc');
    });

    test('convert command without \':\'', (){
      var result = SecondaryUtil.convertCommand('scAn');
      expect(result, 'scan');
    });

  });
}