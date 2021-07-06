import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

var response;
var retryCount = 1;
var maxRetryCount = 5;
var first_atsign = '@alice🛠';
var first_atsign_port = 25000;

var second_atsign = '@bob🛠';
var second_atsign_port = 25003;

var third_atsign = '@emoji🦄🛠';

Socket _socket_first_atsign;
Socket _socket_second_atsign;

var id;
void main() {
  setUp(() async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    _socket_second_atsign =
        await secure_socket_connection(root_server, second_atsign_port);
    socket_listener(_socket_second_atsign);
    await prepare(_socket_second_atsign, second_atsign);
  });

  test('notify verb for notifying a key update to the atsign', () async {
    /// NOTIFY VERB
    await socket_writer(_socket_second_atsign,
        'notify:update:messageType:key:notifier:system:ttr:-1:$first_atsign:email$second_atsign:alice@yahoo.com');
    response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    id = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(_socket_second_atsign);
    print('notify status response : $response');
    assert(response.contains('data:delivered'));

    ///notify:list verb
    await socket_writer(_socket_first_atsign, 'notify:list');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$first_atsign:email$second_atsign","value":"alice@yahoo.com","operation":"update"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb for notifying a text update to another atsign', () async {
    //   /// NOTIFY VERB
    await socket_writer(_socket_second_atsign,
        'notify:update:messageType:text:notifier:chat:ttr:-1:$first_atsign:Hello!!');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    await getNotifyStatus(_socket_second_atsign);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    //   ///notify:list verb
    await socket_writer(_socket_first_atsign, 'notify:list');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$first_atsign:Hello!!","value":null,"operation":"update"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb for deleting a key for other atsign', () async {
    //   /// NOTIFY VERB
    await socket_writer(_socket_first_atsign,
        'notify:delete:messageType:key:notifier:system:ttr:-1:$second_atsign:email$first_atsign');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //  notify status
    await getNotifyStatus(_socket_first_atsign);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    //notify:list verb with regex
    await socket_writer(_socket_second_atsign, 'notify:list:email');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$second_atsign:email$first_atsign","value":null,"operation":"delete"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb without giving message type value', () async {
    /// NOTIFY VERB
    await socket_writer(_socket_first_atsign,
        'notify:update:messageType:notifier:system:ttr:-1:$second_atsign:email$first_atsign');
    var response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('notify verb without giving notifier', () async {
    //   /// NOTIFY VERB
    await socket_writer(_socket_first_atsign,
        'notify:update:messageType:key:ttr:-1:$second_atsign:email$first_atsign');
    var response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('notify verb in an incorrect order', () async {
    /// NOTIFY VERB
    await socket_writer(_socket_first_atsign,
        'notify:messageType:key:update:notifier:system:ttr:-1:$second_atsign:email$first_atsign');
    var response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  // // NOTIFY ALL - UPDATE
  test('notify all for notifiying 2 atsigns at the same time ', () async {
    /// NOTIFY VERB
    await socket_writer(_socket_first_atsign,
        'notify:all:update:messageType:key:ttr:-1:$second_atsign,$third_atsign:twitter$first_atsign:bob_G');
    var response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///notify:list verb with regex
    await Future.delayed(Duration(seconds: 10));
    await socket_writer(_socket_second_atsign, 'notify:list:twitter');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$second_atsign:twitter$first_atsign","value":"bob_G","operation":"update"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  // notify all delete
  test('notify all for notifiying 2 atsigns at the same time for a delete ',
      () async {
    /// NOTIFY VERB
    await socket_writer(_socket_first_atsign,
        'notify:all:delete:messageType:key:ttr:-1:$second_atsign,$third_atsign:twitter$first_atsign');
    var response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///notify:list verb with regex
    await Future.delayed(Duration(seconds: 10));
    await socket_writer(_socket_second_atsign, 'notify:list:twitter');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$second_atsign:twitter$first_atsign","value":"null","operation":"delete"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign.destroy();
    _socket_second_atsign.destroy();
  });
}

// get notify status
Future<String> getNotifyStatus(Socket socket) async {
  while (true) {
    try {
      await socket_writer(socket, 'notify:status:$id');
      response = await read();
      if (response.contains('data:delivered') || retryCount > maxRetryCount) {
        break;
      }
      if (response.contains('data:queued') || response.contains('data:null')) {
        print('Waiting for notification to be delivered.. $retryCount');
        await Future.delayed(Duration(seconds: 5));
        retryCount++;
      }
    } on Exception {
      print('Waiting for result in Exception $retryCount');
      await Future.delayed(Duration(seconds: 5));
      retryCount++;
    }
  }
  return response;
}
