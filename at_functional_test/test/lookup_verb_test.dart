import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var first_atsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var second_atsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  Socket? _socket_first_atsign;
  Socket? _socket_second_atsign;

  //Establish the client socket connection
  setUp(() async {
    var first_atsign_server = ConfigUtil.getYaml()!['root_server']['url'];
    var first_atsign_port =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    var second_atsign_server = ConfigUtil.getYaml()!['root_server']['url'];
    var second_atsign_port =
        ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

    // socket connection for first atsign
    _socket_first_atsign =
        await secure_socket_connection(first_atsign_server, first_atsign_port);
    socket_listener(_socket_first_atsign!);
    await prepare(_socket_first_atsign!, first_atsign);

    //Socket connection for second atsign
    _socket_second_atsign = await secure_socket_connection(
        second_atsign_server, second_atsign_port);
    socket_listener(_socket_second_atsign!);
    await prepare(_socket_second_atsign!, second_atsign);
  });

  test('llookup verb on a non-existent key', () async {
    ///lookup verb alice  atsign
    await socket_writer(_socket_second_atsign!, 'llookup:random$first_atsign');
    var response = await read();
    print('llookup verb response : $response');
    expect(response, contains('key not found : random$first_atsign does not exist in keystore'));
  }, timeout: Timeout(Duration(minutes: 3)));

  test('update-lookup verb on private key - positive verb', () async {
    ///Update verb on bob atsign
    await socket_writer(_socket_first_atsign!,
        'update:$second_atsign:role$first_atsign developer');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb alice  atsign
    await socket_writer(_socket_second_atsign!, 'lookup:role$first_atsign');
    response = await read();
    print('lookup verb response : $response');
    expect(response, contains('data:developer'));
  }, timeout: Timeout(Duration(minutes: 3)));


  test('update-lookup verb by giving wrong spelling - Negative case', () async {
    ///Update verb
    await socket_writer(_socket_second_atsign!,
        'update:public:phone$second_atsign +19012839456');
    var response = await read();
    print('update verb response from $second_atsign : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb
    await socket_writer(
        _socket_first_atsign!, 'lokup:public:phone$second_atsign');
    response = await read();
    print('lookup verb response from $first_atsign : $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(minutes: 3)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign!.destroy();
    _socket_second_atsign!.destroy();
  });
}
