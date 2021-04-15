import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';


void main() {

  var first_atsign = '@bob🛠';
  var first_atsign_port = 25003;

  var second_atsign = '@alice🛠';
  var second_atsign_port = 25000;

  Socket _socket_second_atsign;
  Socket _socket_first_atsign;

  setUp(() async {
    // Socket connection for bob atsign
   var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    //Socket connection for alice atsign
    _socket_second_atsign =
    await secure_socket_connection(root_server, second_atsign_port);
    socket_listener(_socket_second_atsign);
    await prepare(_socket_second_atsign, second_atsign);
  });

  test('update-lookup verb on private key - positive verb', () async {
    ///Update verb on bob atsign
    await socket_writer(_socket_first_atsign, 'update:$second_atsign:role$first_atsign developer');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb alice  atsign
    await socket_writer(_socket_second_atsign, 'lookup:role$first_atsign');
    response = await read();
    print('lookup verb response : $response');
    expect(response, contains('data:developer'));
  }, timeout: Timeout(Duration(seconds: 50)));

  test('update-lookup verb on self key - positive case', () async {
    ///update verb on bob atsign
    await socket_writer(_socket_first_atsign, 'update:work$first_atsign atsign-company');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    await socket_writer(_socket_second_atsign, 'lookup:work$first_atsign');
    response = await read();
    print('lookup verb response : $response');
    expect(response, contains('data:null'));
  }, timeout: Timeout(Duration(seconds: 50)));

  test('update-lookup verb on public key - Negative case', () async {
    ///Update verb
    await socket_writer(
        _socket_second_atsign, 'update:public:location$second_atsign United-States');
    var response = await read();
    print('update verb response from $second_atsign : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb
    await socket_writer(_socket_first_atsign, 'lookup:lookup:location$second_atsign');
    response = await read();
    print('lookup verb response from $first_atsign : $response');
    expect(response, contains('data:null'));
  }, timeout: Timeout(Duration(seconds: 50)));

  test('update-lookup verb by giving wrong spelling - Negative case', () async {
    ///Update verb
    await socket_writer(
        _socket_second_atsign, 'update:public:phone$second_atsign +19012839456');
    var response = await read();
    print('update verb response from $second_atsign : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb
    await socket_writer(_socket_first_atsign, 'lokup:public:phone$second_atsign');
    response = await read();
    print('lookup verb response from $first_atsign : $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 50)));

  tearDown(() {
    //Closing the client socket connection
    _socket_first_atsign.destroy();
    _socket_second_atsign.destroy();
  });
}
