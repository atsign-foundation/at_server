import 'dart:io';

import 'package:test/test.dart';
import 'package:at_end2end_test/conf/config_util.dart';

import 'commons.dart';

void main() {
  var firstAtsign = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var secondAtsign = ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  Socket? socketFirstAtsign;
  Socket? socketSecondAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    var secondAtsignServer = ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_url'];
    var secondAtsignPort = ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign = await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    //Socket connection for second atsign
    socketSecondAtsign = await secure_socket_connection(secondAtsignServer, secondAtsignPort);
    socket_listener(socketSecondAtsign!);
    await prepare(socketSecondAtsign!, secondAtsign);
  });

  test('plookup verb with public key - positive case', () async {
    /// UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:public:phone$firstAtsign 9982212143');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(socketSecondAtsign!, 'plookup:phone$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:9982212143'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with private key - negative case', () async {
    /// UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:$secondAtsign:mobile$firstAtsign 9982212143');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(socketSecondAtsign!, 'plookup:mobile$firstAtsign$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 120)));

  /// Open bug - https://github.com/atsign-foundation/at_server/issues/387
  // test('plookup verb on non existent key - negative case', () async {
  //   ///PLOOKUP VERB
  //   await socket_writer(_socket_first_atsign!, 'plookup:no-key$first_atsign');
  //   var response = await read();
  //   print('plookup verb response $response');
  //   expect(response, contains('data:null'));
  // }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup for an emoji key', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:public:🦄🦄$firstAtsign 2-unicorn-emojis');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('data:null') && (!response.contains('Invalid syntax'))));

    ///PLOOKUP VERB
    await socket_writer(socketSecondAtsign!, 'plookup:🦄🦄$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:2-unicorn-emojis'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup with an extra symbols after the atsign', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:public:emoji-color@emoji🦄🛠 white');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(socketSecondAtsign!, 'plookup:emoji-color@emoji🦄🛠@@@');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('cached key creation when we do a lookup for a public key', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:public:key-1$firstAtsign 9102');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await socket_writer(socketSecondAtsign!, 'plookup:key-1$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:9102'));

    /// SCAN VERB
    await socket_writer(socketSecondAtsign!, 'scan');
    response = await read();
    print('scan verb response $response');
    assert(response.contains('cached:public:key-1$firstAtsign'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with public key -updating same key multiple times', () async {
    /// UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:public:hobbies$firstAtsign Dancing');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key multiple times
    await socket_writer(socketFirstAtsign!, 'plookup:hobbies$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:Dancing'));

    /// UPDATE the same key with a different value
    await socket_writer(socketFirstAtsign!, 'update:public:hobbies$firstAtsign travel photography');
    response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key second time
    await socket_writer(socketFirstAtsign!, 'plookup:hobbies$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:travel photography'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with public key -updating same key multiple times', () async {
    /// UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:public:hobbies$firstAtsign Dancing');
    var response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key multiple times
    await socket_writer(socketFirstAtsign!, 'plookup:hobbies$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:Dancing'));

    /// UPDATE the same key with a different value
    await socket_writer(socketFirstAtsign!, 'update:public:hobbies$firstAtsign travel photography');
    response = await read();
    print('update verb response $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key second time
    await socket_writer(socketFirstAtsign!, 'plookup:hobbies$firstAtsign');
    response = await read();
    print('plookup verb response $response');
    expect(response, contains('data:travel photography'));
  }, timeout: Timeout(Duration(seconds: 120)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
    socketSecondAtsign!.destroy();
  });
}
