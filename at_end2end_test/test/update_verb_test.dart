import 'package:test/test.dart';

import 'commons.dart';

import 'dart:io';
import 'package:at_end2end_test/conf/config_util.dart';

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

  test('update-llookup verb with public key', () async {
    /// UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:location$firstAtsign Hyderabad');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:location$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hyderabad'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup with private key', () async {
    /// UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:$secondAtsign:country$firstAtsign India');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - with @sign returns value
    await socket_writer(
        socketFirstAtsign!, 'llookup:$secondAtsign:country$firstAtsign');
    response = await read();
    print('llookup verb response with private key in llookup verb: $response');
    expect(response, contains('data:India'));

    ///LLOOKUP VERB - with out @sign does not return value.
    await socket_writer(socketFirstAtsign!, 'llookup:country$firstAtsign');
    response = await read();
    print(
        'llookup verb response without private key in llookup verb: $response');
    expect(
        response,
        contains(
            'error:AT0015-key not found : country$firstAtsign does not exist in keystore'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb with special characters', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:passcode$firstAtsign @!ice^&##');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:passcode$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:@!ice^&##'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb with unicode characters', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:unicode$firstAtsign U+0026');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:unicode$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:U+0026'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb with spaces ', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:public:message$firstAtsign Hey Hello! welcome to the tests');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:message$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hey Hello! welcome to the tests'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('updating same key with different values and doing a llookup ',
      () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:public:message$firstAtsign Hey Hello! welcome to the tests');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:message$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hey Hello! welcome to the tests'));

    await socket_writer(socketFirstAtsign!,
        'update:public:message$firstAtsign Hope you are doing good');
    response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:message$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hope you are doing good'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb without value should throw a error ', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:key-1$firstAtsign');
    var response = await read();
    print('update verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb by passing emoji as value ', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:emoji$firstAtsign 🦄');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:emoji$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:🦄'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb by passing japanese input as value ', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:japanese$firstAtsign "パーニマぱーにま"');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:japanese$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:"パーニマぱーにま"'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb by sharing a cached key ', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:ttr:-1:$secondAtsign:yt$firstAtsign john');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB in the same secondary
    await socket_writer(
        socketFirstAtsign!, 'llookup:$secondAtsign:yt$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:john'));

    //LOOKUP VERB in the shared secondary
    await Future.delayed(Duration(seconds: 15));
    await socket_writer(
        socketSecondAtsign!, 'llookup:cached:$secondAtsign:yt$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:john'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update verb by passing 2 @ symbols ', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:country@$firstAtsign USA');
    var response = await read();
    print('update verb response : $response');
    assert(response.contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup for private key for an emoji atsign ', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:@🦄:emoji.name$firstAtsign unicorn');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:@🦄:emoji.name$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:unicorn'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup for ttl ', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:ttl:3000:$secondAtsign:offer$firstAtsign 3seconds');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP:META verb
    await socket_writer(
        socketFirstAtsign!, 'llookup:meta:$secondAtsign:offer$firstAtsign');
    response = await read();
    print('llookup meta response : $response');
    expect(response, contains('"ttl":3000'));

    ///LLOOKUP VERB - Before 10  seconds
    await socket_writer(
        socketFirstAtsign!, 'llookup:$secondAtsign:offer$firstAtsign');
    response = await read();
    print('llookup verb response before 3 seconds : $response');
    expect(response, contains('data:3seconds'));

    ///LLOOKUP VERB - After 10 seconds
    await Future.delayed(Duration(seconds: 1));
    await socket_writer(
        socketFirstAtsign!, 'llookup:$secondAtsign:offer$firstAtsign');
    response = await read();
    print('llookup verb response after 3 seconds : $response');
    expect(response, contains('data:null'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup for ttb ', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:ttb:2000:$secondAtsign:auth-code$firstAtsign 3289');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 10 seconds
    await socket_writer(
        socketFirstAtsign!, 'llookup:$secondAtsign:auth-code$firstAtsign');
    response = await read();
    print('llookup verb response before 2 seconds : $response');
    expect(response, contains('data:null'));

    ///LLOOKUP VERB - After 10 seconds
    await socket_writer(
        socketFirstAtsign!, 'llookup:$secondAtsign:auth-code$firstAtsign');
    response = await read();
    print('llookup verb response after 2 seconds : $response');
    expect(response, contains('data:3289'));

    ///LLookup:META FOR TTB
    await Future.delayed(Duration(seconds: 2));
    await socket_writer(socketFirstAtsign!,
        'llookup:meta:$secondAtsign:auth-code$firstAtsign');
    // await Future.delayed(Duration(seconds: 5));
    response = await read();
    print('llookup meta verb response for ttb is : $response');
    expect(response, contains('"ttb":2000'));
  }, timeout: Timeout(Duration(seconds: 90)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
    socketSecondAtsign!.destroy();
  });
}
