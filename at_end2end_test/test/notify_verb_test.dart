import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_end2end_test/conf/config_util.dart';

var response;
var retryCount = 1;
var maxRetryCount = 18;
int expiryTimeMS = 10000;
var firstAtsign =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
var secondAtsign =
    ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

// Commented as it needs a third atsign
// Will Uncomment once third atsign is added to the config
// var third_atsign =
//     ConfigUtil.getYaml()!['third_atsign_server']['third_atsign_name'];

Socket? socketFirstAtsign;
Socket? socketSecondAtsign;

var id;
void main() {
  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    var secondAtsignServer =
        ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_url'];
    var secondAtsignPort =
        ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    //Socket connection for second atsign
    socketSecondAtsign =
        await secure_socket_connection(secondAtsignServer, secondAtsignPort);
    socket_listener(socketSecondAtsign!);
    await prepare(socketSecondAtsign!, secondAtsign);
  });

  test('notify verb for notifying a key update to the atsign', () async {
    /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:key:notifier:system:ttr:-1:$firstAtsign:email$secondAtsign:alice@yahoo.com');
    response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    id = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(socketSecondAtsign!);
    print('notify status response : $response');
    assert(response.contains('data:delivered'));

    ///notify:list verb
    await socket_writer(socketFirstAtsign!, 'notify:list');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$firstAtsign:email$secondAtsign","value":"alice@yahoo.com","operation":"update"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb without messageType and operation', () async {
    /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:$firstAtsign:contact-no$secondAtsign:+91-9012823465');
    response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    id = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(socketSecondAtsign!);
    print('notify status response : $response');
    assert(response.contains('data:delivered'));

    ///notify:list verb
    await socket_writer(socketFirstAtsign!, 'notify:list');
    response = await read();
    print('notify list verb response : $response');
    expect(response,
        contains('"key":"$firstAtsign:contact-no$secondAtsign","value":null'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb without messageType', () async {
    /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttr:-1:$firstAtsign:fav-city$secondAtsign:Hyderabad');
    response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    id = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(socketSecondAtsign!);
    print('notify status response : $response');
    assert(response.contains('data:delivered'));

    ///notify:list verb
    await socket_writer(socketFirstAtsign!, 'notify:list');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$firstAtsign:fav-city$secondAtsign","value":"Hyderabad","operation":"update"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb for notifying a text update to another atsign', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:text:notifier:chat:ttr:-1:$firstAtsign:Hello!!');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    await getNotifyStatus(socketSecondAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    //   ///notify:list verb
    await socket_writer(socketFirstAtsign!, 'notify:list');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$firstAtsign:Hello!!","value":null,"operation":"update"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb for deleting a key for other atsign', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:delete:messageType:key:notifier:system:ttr:-1:$secondAtsign:email$firstAtsign');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //  notify status
    await getNotifyStatus(socketFirstAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    //notify:list verb with regex
    await socket_writer(socketSecondAtsign!, 'notify:list:email');
    response = await read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$secondAtsign:email$firstAtsign","value":"null","operation":"delete"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb without giving message type value', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:notifier:system:ttr:-1:$secondAtsign:email$firstAtsign');
    var response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('notify verb without giving notifier for strategy latest', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:key:strategy:latest:ttr:-1:$secondAtsign:email$firstAtsign');
    var response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('notify verb with messageType text', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:text:$secondAtsign:Hello!');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    await getNotifyStatus(socketFirstAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with space in the value', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:key:$secondAtsign:company$firstAtsign:Shris Infotech Services');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    await getNotifyStatus(socketFirstAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with messageType text', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:text:$secondAtsign:Hello!');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    await getNotifyStatus(socketFirstAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with space in the value', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:key:$secondAtsign:company$firstAtsign:Shris Infotech Services');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    await getNotifyStatus(socketFirstAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb in an incorrect order', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:messageType:key:update:notifier:system:ttr:-1:$secondAtsign:email$firstAtsign');
    var response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  // Commented the test as it needs a third atsign
  // Uncomment once third atsign is added to the config
  // // NOTIFY ALL - UPDATE
  // test('notify all for notifiying 2 atsigns at the same time ', () async {
  //   /// NOTIFY VERB
  //   await socket_writer(socketFirstAtsign!,
  //       'notify:all:update:messageType:key:ttr:-1:$secondAtsign,$third_atsign:twitter$firstAtsign:bob_G');
  //   var response = await read();
  //   print('notify verb response : $response');
  //   assert(
  //       (!response.contains('Invalid syntax')) && (!response.contains('null')));

  //   ///notify:list verb with regex
  //   await Future.delayed(Duration(seconds: 10));
  //   await socket_writer(socketSecondAtsign!, 'notify:list:twitter');
  //   response = await read();
  //   print('notify list verb response : $response');
  //   expect(
  //       response,
  //       contains(
  //           '"key":"$secondAtsign:twitter$firstAtsign","value":"bob_G","operation":"update"'));
  // }, timeout: Timeout(Duration(seconds: 120)));

  test('notify all for notifiying a single atsign ', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:all:$secondAtsign:whatsapp$firstAtsign:+91-901291029');
    var response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///notify:list verb with regex
    await Future.delayed(Duration(seconds: 10));
    await socket_writer(socketSecondAtsign!, 'notify:list:whatsapp');
    response = await read();
    print('notify list verb response : $response');
    expect(response, contains('"key":"$secondAtsign:whatsapp$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify all for notifiying a single atsign ', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:all:$secondAtsign:whatsapp$firstAtsign:+91-901291029');
    var response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///notify:list verb with regex
    await Future.delayed(Duration(seconds: 10));
    await socket_writer(socketSecondAtsign!, 'notify:list:whatsapp');
    response = await read();
    print('notify list verb response : $response');
    expect(response, contains('"key":"$secondAtsign:whatsapp$firstAtsign"'));
  }, timeout: Timeout(Duration(seconds: 120)));

  // Commented the test as it needs a third atsign
  // Uncomment once third atsign is added to the config
  // notify all delete
  // test('notify all for notifiying 2 atsigns at the same time for a delete ',
  //     () async {
  //   /// NOTIFY VERB
  //   await socket_writer(socketFirstAtsign!,
  //       'notify:all:delete:messageType:key:ttr:-1:$secondAtsign,$third_atsign:twitter$firstAtsign');
  //   var response = await read();
  //   print('notify verb response : $response');
  //   assert(
  //       (!response.contains('Invalid syntax')) && (!response.contains('null')));

  //   ///notify:list verb with regex
  //   await Future.delayed(Duration(seconds: 10));
  //   await socket_writer(socketSecondAtsign!, 'notify:list:twitter');
  //   response = await read();
  //   print('notify list verb response : $response');
  //   expect(
  //       response,
  //       contains(
  //           '"key":"$secondAtsign:twitter$firstAtsign","value":"null","operation":"delete"'));
  // }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb with notification expiry for messageType key', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:key:ttln:8000:ttr:-1:$firstAtsign:message$secondAtsign:Hey!');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //   // notify status before ttln expiry time
    await getNotifyStatus(socketSecondAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    /// notify status after ttln expiry time
    await getNotifyStatus(socketSecondAtsign!, checkExpiry: true);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb with notification expiry for errored- invalid atsign',
      () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:key:ttln:7000:ttr:-1:@xyz:message$secondAtsign:Hey!');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status before ttln expiry time
    await Future.delayed(Duration(seconds: 5));
    await socket_writer(socketSecondAtsign!, 'notify:status:$id');
    response = await read();
    print('notify status response : $response');
    expect(response, contains('data:errored'));

    /// notify status after ttln expiry time
    await getNotifyStatus(socketSecondAtsign!, checkExpiry: true);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('notify verb with notification expiry with messageType text', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:text:ttln:8000:ttr:-1:$firstAtsign:Helllo!');
    response = await read();
    print('notify verb response : $response');
    id = response.replaceAll('data:', '');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status before ttln expiry time
    await getNotifyStatus(socketSecondAtsign!);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    /// notify status after ttln expiry time
    await getNotifyStatus(socketSecondAtsign!, checkExpiry: true);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  }, skip: "There's a timing issue here");

  ///
  test('notify verb with notification expiry in an incorrect spelling',
      () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttlnn:5000:ttr:-1:$firstAtsign:message$secondAtsign:Hey!');
    response = await read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('notify verb with notification expiry without value for ttln', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttln:ttr:-1:$firstAtsign:message$secondAtsign:Hey!');
    response = await read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('notify verb with notification expiry in an incorrect order', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttb:3000:ttr:-1:ttln:10000:$firstAtsign:message$secondAtsign:Hey!');
    response = await read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
    socketSecondAtsign!.destroy();
  });
}

// get notify status
Future<String> getNotifyStatus(Socket socket,
    {bool checkExpiry = false}) async {
  while (true) {
    try {
      await socket_writer(socket, 'notify:status:$id');
      response = await read();
      print ('status response: $response');
       if (checkExpiry) {
        if (response.contains('data:expired')) {
          break;
        }
        if (response.contains('data:delivered') ||
            (response.contains('data:queued'))) {
          print('waiting for the notification expiry .. $retryCount');
          await Future.delayed(Duration(seconds: 2));
          retryCount++;
        }
      }
      if (response.contains('data:delivered') || retryCount > maxRetryCount) {
        break;
      }
      if(response.contains('data:errored')){
        print('Failed notification ');
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
