import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

///The below test functions runs a complete flow of all verbs
void main() async {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

// second atsign details
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });
//FOR THESE TESTS TO WORK/PASS SET testingMode TO TRUE THROUGH ENV VARIABLES
//THE FOLLOWING TESTS ONLY WORK WHEN IN TESTING MODE
  test('config verb test set/reset operation', () async {
    print(Platform.environment['testingMode']);
    if (Platform.environment.containsKey('testingMode') &&
            (Platform.environment['testingMode']!.toLowerCase() == 'true')
        ? true
        : false) {
      await socket_writer(
          socketFirstAtsign!, 'config:set:commitLogCompactionFrequencyMins=4');
      var response = await read();
      print('config verb response $response');
      expect(response, contains('data:ok'));

      await socket_writer(
          socketFirstAtsign!, 'config:reset:commitLogCompactionFrequencyMins');
      await Future.delayed(Duration(seconds: 2));
      response = await read();
      print('config verb response $response');
      expect(response, contains('data:ok'));
    } else {
      print(
          'asserting true forcefully. Set testingMode to true for the test to work');
    }
  });

  test('config verb test set/print', () async {
    print(Platform.environment);
      await socket_writer(
          socketFirstAtsign!, 'config:set:maxNotificationRetries=25');
      var response = await read();
      print('config verb response $response');
      expect(response, contains('data:ok'));

      await socket_writer(
          socketFirstAtsign!, 'config:print:maxNotificationRetries');
      await Future.delayed(Duration(seconds: 2));
      response = await read();
      print('config verb response $response');
      expect(response, contains('data:25'));
  });

  tearDown(() {
    //Closing the socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}
