import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var first_atsign = '@bob🛠';
  var first_atsign_port = 25003;


  var second_atsign = '@emoji🦄🛠';
  var second_atsign_port = 25009;

  Socket _socket_first_atsign;
  Socket _socket_second_atsign;

  test('Scan verb after authentication', () async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    ///UPDATE VERB
    await socket_writer(
        _socket_first_atsign, 'update:public:location$first_atsign California');
    var response = await read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(_socket_first_atsign, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"public:location$first_atsign"'));
  },timeout: Timeout(Duration(seconds: 120)));

  test('scan verb before authentication', () async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);

    ///SCAN VERB
    await socket_writer(_socket_first_atsign, 'scan');
    var response = await read();
    print('scan verb response : $response');
    expect(response, contains('"location$first_atsign"'));
  },timeout: Timeout(Duration(seconds: 120)));

  test('Scan verb with only atsign and no value', () async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    ///SCAN VERB
    await socket_writer(_socket_first_atsign, 'scan@');
    var response = await read();
    print('scan verb response : $response');
    expect(response, contains('Invalid syntax'));
  },timeout: Timeout(Duration(seconds: 120)));

  test('Scan verb with regex', () async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);
    
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:twitter.me$first_atsign bob_123');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(_socket_first_atsign, 'scan .me');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"public:twitter.me$first_atsign"'));
  },timeout: Timeout(Duration(seconds: 120)));

  test('scan verb with emoji', () async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    var root_server1 = ConfigUtil.getYaml()['root_server']['url'];
    _socket_second_atsign =
        await secure_socket_connection(root_server1, second_atsign_port);
    socket_listener(_socket_second_atsign);
    await prepare(_socket_second_atsign, second_atsign);

    ///UPDATE VERB
    await socket_writer(_socket_second_atsign, 'update:$first_atsign:emoticon$second_atsign unicorn');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(_socket_first_atsign, 'scan:$second_atsign');
    response = await read();
    await Future.delayed(Duration(seconds: 5));
    print('scan verb response : $response');
    expect(response, contains('"emoticon$second_atsign"'));
  },timeout: Timeout(Duration(seconds: 120)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign.destroy();
  });
}
