import 'package:at_secondary/src/utils/system_util.dart';
import 'package:test/test.dart';

void main() {
  group('group of system test', () {
    test('get last logged in datetime', () async {
      var result = await SystemUtil.getLastLoggedInTime();
      print(result);
    });

    test('get disk size', () async {
      var result = await SystemUtil.getDiskSize();
      print(result);
    });
  });
}