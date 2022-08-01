import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var firstAtsignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];
  var secondAtsignPort =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

  Socket? socketFirstAtsign;
  Socket? socketSecondAtsign;

  setUp(() async {
    socketFirstAtsign =
        await secure_socket_connection('vip.ve.atsign.zone', firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    socketSecondAtsign =
        await secure_socket_connection('vip.ve.atsign.zone', secondAtsignPort);
    socket_listener(socketSecondAtsign!);
    await prepare(socketSecondAtsign!, secondAtsign);
  });

  test('connection limit test', () async {
    try {
      // setting the inbound connection limit to 2
      await socket_writer(socketFirstAtsign!, 'config:set:inbound_max_limit=2');
      var response = await read();
      print('response of config verb is $response');
      expect(response, contains('data:ok'));

      ///update verb alice  atsign
      await socket_writer(
          socketFirstAtsign!, 'update:$secondAtsign:code$firstAtsign 9900');
      response = await read();
      print('update verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));

      // lookup from receiver atsign
      await Future.delayed(Duration(seconds: 3));
      await socket_writer(socketSecondAtsign!, 'lookup:code$firstAtsign');
      response = await read();
      print('lookup verb response : $response');
      expect(response, contains('9900'));

      await socket_writer(socketSecondAtsign!,
          'update:$firstAtsign:sample-text2$secondAtsign Hello!');
      response = await read();
      print('update verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));

      await Future.delayed(Duration(seconds: 3));
      await socket_writer(
          socketFirstAtsign!, 'lookup:sample-text2$secondAtsign');
      response = await read();
      print('lookup verb response : $response');
      expect(
          response, contains('error:AT0012-Inbound connection limit exceeded'));
    } finally {
      // resetting the inbound connection limit to default
      await socket_writer(socketFirstAtsign!, 'config:reset:inbound_max_limit');
      var response = await read();
      print('response of config verb is $response');
      expect(response, contains('data:ok'));
    }
  }, timeout: Timeout(Duration(minutes: 10)));
}
