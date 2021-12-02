import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var firstAtsignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

  // var secondAtsign =
  //     ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];
  // var secondAtsignPort =
  //     ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

  Socket? socketFirstAtsign;
  // Socket? SocketSecondAtsign;

  test('Scan verb after authentication', () async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:location$firstAtsign California');
    var response = await read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"public:location$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('scan verb before authentication', () async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    var response = await read();
    print('scan verb response : $response');
    expect(response, contains('"location$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('Scan verb with only atsign and no value', () async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan@');
    var response = await read();
    print('scan verb response : $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('Scan verb with regex', () async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:twitter.me$firstAtsign bob_123');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan .me');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"public:twitter.me$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}
