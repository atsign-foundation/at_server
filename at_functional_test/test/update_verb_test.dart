import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

import 'dart:io';

void main() {
  var first_atsign =
      ConfigUtil.getYaml()['first_atsign_server']['first_atsign_name'];
  var second_atsign =
      ConfigUtil.getYaml()['second_atsign_server']['second_atsign_name'];

  Socket _socket_first_atsign;
  Socket _socket_second_atsign;

  //Establish the client socket connection
  setUp(() async {
    var first_atsign_server =
        ConfigUtil.getYaml()['first_atsign_server']['first_atsign_url'];
    var first_atsign_port =
        ConfigUtil.getYaml()['first_atsign_server']['first_atsign_port'];

    var second_atsign_server =
        ConfigUtil.getYaml()['second_atsign_server']['second_atsign_url'];
    var second_atsign_port =
        ConfigUtil.getYaml()['second_atsign_server']['second_atsign_port'];

    // socket connection for first atsign
    _socket_first_atsign =
        await secure_socket_connection(first_atsign_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    //Socket connection for second atsign
    _socket_second_atsign =
        await secure_socket_connection(second_atsign_server, second_atsign_port);
    socket_listener(_socket_second_atsign);
    await prepare(_socket_second_atsign, second_atsign);
  });

  test('update-llookup verb with public key', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:location$first_atsign Hyderabad');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:public:location$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hyderabad'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup with private key', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:$second_atsign:country$first_atsign India');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - with @sign returns value
    await socket_writer(_socket_first_atsign, 'llookup:$second_atsign:country$first_atsign');
    response = await read();
    print('llookup verb response with private key in llookup verb: $response');
    expect(response, contains('data:India'));

    ///LLOOKUP VERB - with out @sign does not return value.
    await socket_writer(_socket_first_atsign, 'llookup:country$first_atsign');
    response = await read();
    print(
        'llookup verb response without private key in llookup verb: $response');
    expect(response, contains('data:null'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb with special characters', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:passcode$first_atsign @!ice^&##');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:public:passcode$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response,contains('data:@!ice^&##'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb with unicode characters', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:unicode$first_atsign U+0026');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:public:unicode$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:U+0026'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb with address ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign,
        'update:public:address$first_atsign "plot no-103,Essar enclave,Hyderabad-500083"');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:public:address$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response,contains(
        'data:"plot no-103,Essar enclave,Hyderabad-500083"'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb without value should throw a error ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:key-1$first_atsign');
    var response = await read();
    print('update verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb by passing emoji as value ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:emoji$first_atsign 🦄');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:public:emoji$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:🦄'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb by passing japanese input as value ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:japanese$first_atsign "パーニマぱーにま"');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:public:japanese$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:"パーニマぱーにま"'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb by sharing a cached key ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:ttr:-1:$second_atsign:xbox1$first_atsign player123');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    // ///LLOOKUP VERB in the same secondary
    await socket_writer(_socket_first_atsign, 'llookup:$second_atsign:xbox1$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:player123'));

    //LOOKUP VERB in the shared secondary
    await socket_writer(_socket_second_atsign, 'llookup:cached:$second_atsign:xbox1$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:player123'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb by passing 2 @ symbols ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:public:country@$first_atsign USA');
    var response = await read();
    print('update verb response : $response');
    assert(response.contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup for private key for an emoji atsign ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:@🦄:emoji.name$first_atsign unicorn');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:@🦄:emoji.name$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:unicorn'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup for ttl ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:ttl:3000:$second_atsign:offer$first_atsign 3seconds');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP:META verb
    await  socket_writer(_socket_first_atsign, 'llookup:meta:$second_atsign:offer$first_atsign');
    response = await read();
    print('llookup meta response : $response');
    expect(response, contains('"ttl":3000'));

    ///LLOOKUP VERB - Before 10  seconds
    await socket_writer(_socket_first_atsign, 'llookup:$second_atsign:offer$first_atsign');
    response = await read();
    print('llookup verb response before 3 seconds : $response');
    expect(response, contains('data:3seconds'));

    ///LLOOKUP VERB - After 10 seconds
    await socket_writer(_socket_first_atsign, 'llookup:$second_atsign:offer$first_atsign');
    response = await read();
    print('llookup verb response after 3 seconds : $response');
    expect(response, contains('data:null'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup for ttb ', () async {
    ///UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:ttb:2000:$second_atsign:auth-code$first_atsign 3289');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 10 seconds
    await socket_writer(_socket_first_atsign, 'llookup:$second_atsign:auth-code$first_atsign');
    response = await read();
    print('llookup verb response before 2 seconds : $response');
    expect(response, contains('data:null'));

    ///LLOOKUP VERB - After 10 seconds
    await socket_writer(_socket_first_atsign, 'llookup:$second_atsign:auth-code$first_atsign');
    response = await read();
    print('llookup verb response after 2 seconds : $response');
    expect(response, contains('data:3289'));

    ///LLookup:META FOR TTB
    await socket_writer(_socket_first_atsign, 'llookup:meta:$second_atsign:auth-code$first_atsign');
    // await Future.delayed(Duration(seconds: 5));
    response = await read();
    print('llookup meta verb response for ttb is : $response');
    expect(response, contains('"ttb":2000'));
  }, timeout: Timeout(Duration(seconds: 90)));


  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign.destroy();
  });
}
