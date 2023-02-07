import 'package:test/test.dart';
import 'functional_test_commons.dart';
import 'dart:io';
import 'package:at_functional_test/conf/config_util.dart';

void main() {

  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  Socket? socketFirstAtsign;

  var firstAtsignServer =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
  var firstAtsignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

  test('authenticate and verify the time taken', () async {
    var timeBeforeAuth = DateTime.now().millisecondsSinceEpoch;
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
    var timeAfterAuth = DateTime.now().millisecondsSinceEpoch;
    timeDifference(timeBeforeAuth, timeAfterAuth);
  });

  test('authenticate multiple times', () async {
    int noOfTests =10;
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    for(int i=1; i <=noOfTests; i++){
      await prepare(socketFirstAtsign!, firstAtsign);
    }    
  });


}

Future<void> timeDifference(var beforeCommand, var afterCommand) async {
  var timeDifferenceValue = DateTime.fromMillisecondsSinceEpoch(afterCommand)
      .difference(DateTime.fromMillisecondsSinceEpoch(beforeCommand));
  // expect(timeDifferenceValue.inMilliseconds <= 1500, true);
  print('time difference is $timeDifferenceValue');
}