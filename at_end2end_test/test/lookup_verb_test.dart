import 'dart:io';

import 'package:at_end2end_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  Socket? socketFirstAtsign;
  Socket? socketSecondAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    var secondAtsignServer = ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_url'];
    var secondAtsignPort =
        ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    //Socket connection for second atsign
    socketSecondAtsign = await secure_socket_connection(
        secondAtsignServer, secondAtsignPort);
    socket_listener(socketSecondAtsign!);
    await prepare(socketSecondAtsign!, secondAtsign);
  });

  test('llookup verb on a non-existent key', () async {
    ///lookup verb alice  atsign
    await socket_writer(socketSecondAtsign!, 'llookup:random$firstAtsign');
    var response = await read();
    print('llookup verb response : $response');
    expect(response, contains('key not found : random$firstAtsign does not exist in keystore'));
  }, timeout: Timeout(Duration(minutes: 3)));

  test('update-lookup verb on private key - positive verb', () async {
    ///Update verb on bob atsign
    await socket_writer(socketFirstAtsign!,
        'update:$secondAtsign:role$firstAtsign developer');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb alice  atsign
    await socket_writer(socketSecondAtsign!, 'lookup:role$firstAtsign');
    response = await read();
    print('lookup verb response : $response');
    expect(response, contains('data:developer'));
  }, timeout: Timeout(Duration(minutes: 3)));


  test('update-lookup verb by giving wrong spelling - Negative case', () async {
    ///Update verb
    await socket_writer(socketSecondAtsign!,
        'update:public:phone$secondAtsign +19012839456');
    var response = await read();
    print('update verb response from $secondAtsign : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb
    await socket_writer(
        socketFirstAtsign!, 'lokup:public:phone$secondAtsign');
    response = await read();
    print('lookup verb response from $firstAtsign : $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(minutes: 3)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
    socketSecondAtsign!.destroy();
  });
}
