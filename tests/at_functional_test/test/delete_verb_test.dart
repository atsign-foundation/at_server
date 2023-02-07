import 'package:test/test.dart';

import 'functional_test_commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'dart:io';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  Socket? socketFirstAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('Delete verb for public key', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:location$firstAtsign Bengaluru');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response before delete : $response');
    expect(response, contains('public:location$firstAtsign'));

    ///DELETE VERB
    await socket_writer(
        socketFirstAtsign!, 'delete:public:location$firstAtsign');
    response = await read();
    print('delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response after delete : $response');
    expect(response, isNot('public:location$firstAtsign'));
  }, timeout: Timeout(Duration(seconds: 50)));

  test('delete verb with incorrect spelling - negative scenario', () async {
    ///Delete verb
    await socket_writer(socketFirstAtsign!, 'deete:phone$firstAtsign');
    var response = await read();
    print('delete verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('delete verb for an emoji key', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:🦄🦄$firstAtsign 2emojis');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response is :$response');
    expect(response, contains('public:🦄🦄$firstAtsign'));

    ///DELETE VERB
    await socket_writer(socketFirstAtsign!, 'delete:public:🦄🦄$firstAtsign');
    response = await read();
    print('delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response is :$response');
    expect(response, isNot('public:🦄🦄$firstAtsign'));
  });

  test('delete verb when ccd is true', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:ttr:-1:ccd:true:$secondAtsign:hobby$firstAtsign photography');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    ;

    ///SCAN VERB in the first atsign
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response before delete : $response');
    expect(response, contains('"$secondAtsign:hobby$firstAtsign"'));

    // ///DELETE VERB
    await socket_writer(
        socketFirstAtsign!, 'delete:$secondAtsign:hobby$firstAtsign');
    response = await read();
    print('delete verb response : $response');
    assert(!response.contains('data:null'));

    // ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response after delete : $response');
    expect(response, isNot('"$secondAtsign:hobby$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 60)));

  test('Delete verb - delete non existent key', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:location$firstAtsign India');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(socketFirstAtsign!, 'scan');
    response = await read();
    print('scan verb response before delete : $response');
    expect(response, contains('location$firstAtsign'));

    ///DELETE VERB
    await socket_writer(socketFirstAtsign!, 'delete:location$firstAtsign');
    response = await read();
    print('delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///DELETE VERB AGAIN
    await socket_writer(socketFirstAtsign!, 'delete:location$firstAtsign');
    response = await read();
    print('delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
  }, timeout: Timeout(Duration(seconds: 50)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}
