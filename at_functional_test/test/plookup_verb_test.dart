import 'dart:io';

import 'package:test/test.dart';
import 'package:at_functional_test/conf/config_util.dart';

import 'commons.dart';

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

  test('plookup verb with public key - positive case', () async {
    /// UPDATE VERB
    await socket_writer(
        _socket_first_atsign!, 'update:public:phone$first_atsign 9982212143');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(_socket_second_atsign!, 'plookup:phone$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:9982212143'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with private key - negative case', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign!,
        'update:$second_atsign:mobile$first_atsign 9982212143');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(
        _socket_second_atsign!, 'plookup:mobile$first_atsign$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb on non existent key - negative case', () async {
    ///PLOOKUP VERB
    await socket_writer(_socket_first_atsign!, 'plookup:no-key$first_atsign');
    var response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:null'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup for an emoji key', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign!,
        'update:public:🦄🦄$first_atsign 2-unicorn-emojis');
    var response = await read();
    print('update verb response $response');
    assert(!(response.contains('data:null') &&
        (response.contains('Invalid syntax'))));

    ///PLOOKUP VERB
    await socket_writer(_socket_second_atsign!, 'plookup:🦄🦄$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:2-unicorn-emojis'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup with an extra symbols after the atsign', () async {
    ///UPDATE VERB
    await socket_writer(
        _socket_first_atsign!, 'update:public:emoji-color@emoji🦄🛠 white');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(
        _socket_second_atsign!, 'plookup:emoji-color@emoji🦄🛠@@@');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('cached key creation when we do a lookup for a public key', () async {
    ///UPDATE VERB
    await socket_writer(
        _socket_first_atsign!, 'update:public:key-1$first_atsign 9102');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(_socket_second_atsign!, 'plookup:key-1$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:9102'));

    /// SCAN VERB
    await socket_writer(_socket_second_atsign!, 'scan');
    response = await read();
    print('scan verb response $response');
    assert(response.contains('cached:public:key-1$first_atsign'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with public key -updating same key multiple times',
      () async {
    /// UPDATE VERB
    await socket_writer(
        _socket_first_atsign!, 'update:public:hobbies$first_atsign Dancing');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key multiple times
    await socket_writer(_socket_first_atsign!, 'plookup:hobbies$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:Dancing'));

    /// UPDATE the same key with a different value
    await socket_writer(_socket_first_atsign!,
        'update:public:hobbies$first_atsign travel photography');
    response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key second time
    await socket_writer(_socket_first_atsign!, 'plookup:hobbies$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:travel photography'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with public key -updating same key multiple times', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign!, 'update:public:hobbies$first_atsign Dancing');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key multiple times
    await socket_writer(_socket_first_atsign!, 'plookup:hobbies$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:Dancing'));

    /// UPDATE the same key with a different value
    await socket_writer(_socket_first_atsign!, 'update:public:hobbies$first_atsign travel photography');
    response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key second time
    await socket_writer(_socket_first_atsign!, 'plookup:hobbies$first_atsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:travel photography'));
  },timeout: Timeout(Duration(seconds: 120)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign!.destroy();
    _socket_second_atsign!.destroy();
  });
}
