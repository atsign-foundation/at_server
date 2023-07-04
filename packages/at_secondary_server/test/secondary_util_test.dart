import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:test/test.dart';

void main() {
  group('group of command conversion test', () {
    test('convert command', () {
      var result = SecondaryUtil.convertCommand('Update:privatekey:abc HelLo');
      expect(result, 'update:privatekey:abc HelLo');
    });
  });

  group('group of tests for client version compare', () {
    test('patch version test - current version less than target version', () {
      var result = SecondaryUtil.isVersionGreater('3.0.61', '3.0.62');
      expect(false, result);
    });
    test('patch version test -  current version greater than target version',
        () {
      var result = SecondaryUtil.isVersionGreater('3.0.63', '3.0.62');
      expect(true, result);
    });
    test('patch version test - current version is equal target version', () {
      var result = SecondaryUtil.isVersionGreater('3.0.62', '3.0.62');
      expect(false, result);
    });
    test('minor version test - current version less than target version', () {
      var result = SecondaryUtil.isVersionGreater('3.0.0', '3.1.0');
      expect(false, result);
    });
    test('minor version test -  current version greater than target version',
        () {
      var result = SecondaryUtil.isVersionGreater('3.2.0', '3.1.0');
      expect(true, result);
    });
    test('minor version test - current version is equal target version', () {
      var result = SecondaryUtil.isVersionGreater('3.1.0', '3.1.0');
      expect(false, result);
    });
    test('major version test - current version less than target version', () {
      var result = SecondaryUtil.isVersionGreater('3.0.0', '4.0.0');
      expect(false, result);
    });
    test('major version test -  current version greater than target version',
        () {
      var result = SecondaryUtil.isVersionGreater('5.0.0', '4.0.0');
      expect(true, result);
    });
    test('major version test - current version is equal target version', () {
      var result = SecondaryUtil.isVersionGreater('4.0.0', '4.0.0');
      expect(false, result);
    });
  });
}
