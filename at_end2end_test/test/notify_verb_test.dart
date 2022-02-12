import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_end2end_test/conf/config_util.dart';

var firstAtsign =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
var secondAtsign =
    ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

Socket? socketFirstAtsign;
Socket? socketSecondAtsign;

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
    String response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
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
  });

  test('notify verb without messageType and operation', () async {
    /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:$firstAtsign:contact-no$secondAtsign:+91-9012823465');
    String response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
    print('notify status response : $response');
    assert(response.contains('data:delivered'));

    ///notify:list verb
    await socket_writer(socketFirstAtsign!, 'notify:list');
    response = await read();
    print('notify list verb response : $response');
    expect(response,
        contains('"key":"$firstAtsign:contact-no$secondAtsign","value":null'));
  });

  test('notify verb without messageType', () async {
    /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttr:-1:$firstAtsign:fav-city$secondAtsign:Hyderabad');
    String response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
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
  });

  test('notify verb for notifying a text update to another atsign', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:text:notifier:chat:ttr:-1:$firstAtsign:Hello!!');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
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
  });

  test('notify verb for deleting a key for other atsign', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:delete:messageType:key:notifier:system:ttr:-1:$secondAtsign:email$firstAtsign');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //  notify status
    response = await getNotifyStatus(socketFirstAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
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
  });

  test('notify verb without giving message type value', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:notifier:system:ttr:-1:$secondAtsign:email$firstAtsign');
    String response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('notify verb without giving notifier for strategy latest', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:key:strategy:latest:ttr:-1:$secondAtsign:email$firstAtsign');
    String response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('notify verb with messageType text', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:text:$secondAtsign:Hello!');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(socketFirstAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with space in the value', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:key:$secondAtsign:company$firstAtsign:Shris Infotech Services');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(socketFirstAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with messageType text', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:text:$secondAtsign:Hello!');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(socketFirstAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with space in the value', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:update:messageType:key:$secondAtsign:company$firstAtsign:Shris Infotech Services');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(socketFirstAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb in an incorrect order', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:messageType:key:update:notifier:system:ttr:-1:$secondAtsign:email$firstAtsign');
    String response = await read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  // Commented the test as it needs a third atsign
  // Uncomment once third atsign is added to the config
  // // NOTIFY ALL - UPDATE
  // test('notify all for notifying 2 atSigns at the same time ', () async {
  //   /// NOTIFY VERB
  //   await socket_writer(socketFirstAtsign!,
  //       'notify:all:update:messageType:key:ttr:-1:$secondAtsign,$third_atsign:twitter$firstAtsign:bob_G');
  //   String response = await read();
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
  // });

  test('notify all for notifying a single atsign ', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:all:$secondAtsign:whatsapp$firstAtsign:+91-901291029');
    String response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///notify:list verb with regex
    await Future.delayed(Duration(seconds: 10));
    await socket_writer(socketSecondAtsign!, 'notify:list:whatsapp');
    response = await read();
    print('notify list verb response : $response');
    expect(response, contains('"key":"$secondAtsign:whatsapp$firstAtsign"'));
  });

  test('notify all for notifying a single atsign ', () async {
    /// NOTIFY VERB
    await socket_writer(socketFirstAtsign!,
        'notify:all:$secondAtsign:whatsapp$firstAtsign:+91-901291029');
    String response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///notify:list verb with regex
    await Future.delayed(Duration(seconds: 10));
    await socket_writer(socketSecondAtsign!, 'notify:list:whatsapp');
    response = await read();
    print('notify list verb response : $response');
    expect(response, contains('"key":"$secondAtsign:whatsapp$firstAtsign"'));
  });

  // Commented the test as it needs a third atsign
  // Uncomment once third atsign is added to the config
  // notify all delete
  // test('notify all for notifying 2 atSigns at the same time for a delete ',
  //     () async {
  //   /// NOTIFY VERB
  //   await socket_writer(socketFirstAtsign!,
  //       'notify:all:delete:messageType:key:ttr:-1:$secondAtsign,$third_atsign:twitter$firstAtsign');
  //   String response = await read();
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
  // });

  test('notify verb with notification expiry for messageType key', () async {
    //   /// NOTIFY VERB
    int ttln=6000;
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:key:ttln:$ttln:ttr:-1:$firstAtsign:message$secondAtsign:Hey!');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    int willExpireAt = DateTime.now().millisecondsSinceEpoch + ttln;

    //   // notify status before ttln expiry time
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    // Wait until ttln has been reached
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now < willExpireAt) {
      await Future.delayed(Duration(milliseconds: willExpireAt - now));
    }

    /// notify status after ttln expiry time
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['expired'], waitTimeMillis: 1000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  });

  test('notify verb with notification expiry for errored- invalid atsign', () async {
    //   /// NOTIFY VERB
    int ttln = 6000;
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:key:ttln:$ttln:ttr:-1:@xyz:message$secondAtsign:Hey!');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    int willExpireAt = DateTime.now().millisecondsSinceEpoch + ttln;

    // notify status before ttln expiry time
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['errored'], waitTimeMillis: 3000);
    expect(response, contains('data:errored'));

    // Wait until ttln has been reached
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now < willExpireAt) {
      await Future.delayed(Duration(milliseconds: willExpireAt - now));
    }
    /// notify status after ttln expiry time
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['expired'], waitTimeMillis: 1000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  });

  test('notify verb with notification expiry with messageType text', () async {
    //   /// NOTIFY VERB
    int ttln = 6000;
    await socket_writer(socketSecondAtsign!,
        'notify:update:messageType:text:ttln:$ttln:ttr:-1:$firstAtsign:Hello!');
    String response = await read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    int willExpireAt = DateTime.now().millisecondsSinceEpoch + ttln;

    // notify status before ttln expiry time
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['delivered'], waitTimeMillis: 3000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    // Wait until ttln has been reached
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now < willExpireAt) {
      await Future.delayed(Duration(milliseconds: willExpireAt - now));
    }

    /// notify status after ttln expiry time
    response = await getNotifyStatus(socketSecondAtsign!, notificationId, returnWhenStatusIn: ['expired'], waitTimeMillis: 1000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  });

  ///
  test('notify verb with notification expiry in an incorrect spelling',
      () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttlnn:5000:ttr:-1:$firstAtsign:message$secondAtsign:Hey!');
    String response = await read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('notify verb with notification expiry without value for ttln', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttln:ttr:-1:$firstAtsign:message$secondAtsign:Hey!');
    String response = await read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('notify verb with notification expiry in an incorrect order', () async {
    //   /// NOTIFY VERB
    await socket_writer(socketSecondAtsign!,
        'notify:update:ttb:3000:ttr:-1:ttln:10000:$firstAtsign:message$secondAtsign:Hey!');
    String response = await read();
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
Future<String> getNotifyStatus(Socket socket, String notificationId, {List<String>? returnWhenStatusIn, int waitTimeMillis = 5000}) async {
  returnWhenStatusIn ??= ['expired'];
  print ("getNotifyStatus will check for notify:status response in '$returnWhenStatusIn' for $waitTimeMillis");
  int singleTryWaitMillis = 50;
  int numTries = (waitTimeMillis / singleTryWaitMillis).round();
  String response = 'NO_RESPONSE';
  for (int i = 0; i < numTries; i++) {
    await Future.delayed(Duration(milliseconds: singleTryWaitMillis));
    await socket_writer(socket, 'notify:status:$notificationId');
    response = await read();

    if (response.startsWith('data:')) {
      String status = response.replaceFirst('data:', '').replaceAll('\n', '');
      if (returnWhenStatusIn.contains(status)) {
        break;
      }
    }
  }
  print ("getNotifyStatus return with response $response (was waiting for '$returnWhenStatusIn')");

  return response;
}
