import 'package:at_utils/at_logger.dart';
import 'package:process_run/shell.dart';

class SystemUtil {
  static var logger = AtSignLogger('SystemUtil');

  static Future<String> getLastLoggedInTime() async {
    var result = await Shell().run('whoami');
    var user = result[0].stdout.toString();
    var command = 'last ${user}';
    result = await Shell().run('$command');
    var res = result[0].stdout.toString().split('\n')[0];
    var output = res.replaceAll(RegExp(' +'), ' ').split(' ');
    return '${output[3]} ${output[4]} ${output[5]} ${output[6]}';
  }

  static Future<String> getDiskSize() async {
    var result =
        await Shell().runExecutableArguments('df', ['-h', '/dev/sda1']);

    if (result.stdout.toString().split('\n')[1].isNotEmpty) {
      return result.stdout
          .toString()
          .split('\n')[1]
          .replaceAll(RegExp(' +'), ' ')
          .split(' ')[3];
    }
    return '0G';
  }
}
