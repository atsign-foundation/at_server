import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var firstAtsignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

  Socket? socketFirstAtsign;

  test('Scan verb after authentication', () async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
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
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
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
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
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
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
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

  // test('Scan verb - Displays key with special characters', () async {
  //   var firstAtsignServer =
  //       ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
  //   socketFirstAtsign =
  //       await secure_socket_connection(firstAtsignServer, firstAtsignPort);
  //   socket_listener(socketFirstAtsign!);
  //   await prepare(socketFirstAtsign!, firstAtsign);
  //
  //   ///UPDATE VERB
  //   await socket_writer(socketFirstAtsign!,
  //       'update:public:verifying,commas$firstAtsign Working?');
  //   var response = await read();
  //   print('update verb response : $response');
  //   assert(
  //       (!response.contains('Invalid syntax')) && (!response.contains('null')));
  //
  //   ///SCAN VERB
  //   await socket_writer(socketFirstAtsign!, 'scan');
  //   response = await read();
  //   print('scan verb response : $response');
  //   expect(response, contains('"public:verifying,commas$firstAtsign"'));
  // }, timeout: Timeout(Duration(seconds: 120)));

  test('Scan verb does not return expired keys', () async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:ttl:3000:ttlkey.me$firstAtsign 1245');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB should return the key before it expires
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"ttlkey.me$firstAtsign"'));

    // update ttl to a lesser value so that key expires for scan
    await socket_writer(
        socketFirstAtsign!, 'update:ttl:200:ttlkey.me$firstAtsign 1245');
    response = await read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //  scan verb should not return the expired key
    await Future.delayed(Duration(milliseconds: 300));
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(false, response.contains('"ttlkey.me$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('Scan verb does not return unborn keys', () async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:ttb:4000:ttbkey$firstAtsign Working?');
    var response = await read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // scan verb should not return the unborn key
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(false, response.contains('"ttbkey$firstAtsign"'));

    // update ttb to a lesser value so that key becomes born
    await socket_writer(
        socketFirstAtsign!, 'update:ttb:200:ttbkey$firstAtsign Working?');
    response = await read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //  scan verb should return the born key
    await Future.delayed(Duration(milliseconds: 300));
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"ttbkey$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}
