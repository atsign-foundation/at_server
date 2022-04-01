import 'dart:math';

import 'package:test/test.dart';

import 'e2e_test_utils.dart' as e2e;

void main() {
  late String atSign_1;
  late e2e.SimpleOutboundSocketHandler sh1;

  late String atSign_2;
  late e2e.SimpleOutboundSocketHandler sh2;

  var lastValue = Random().nextInt(30);

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();
    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() async {
    print("Clearing socket response queues");
    sh1.clear();
    sh2.clear();
  });

  test('notify verb for notifying a key update to the atsign', () async {
    /// NOTIFY VERB
    var value = 'alice$lastValue@yahoo.com';
    await sh2.writeCommand(
        'notify:update:messageType:key:notifier:system:ttr:-1:$atSign_1:email$atSign_2:$value');
    String response = await sh2.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    ///notify:list verb
    await sh1.writeCommand('notify:list');
    response = await sh1.read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$atSign_1:email$atSign_2","value":"$value","operation":"update"'));
  });

  test('notify verb without messageType and operation', () async {
    /// NOTIFY VERB
    var value = '+91-901282346$lastValue';
    await sh2
        .writeCommand('notify:$atSign_1:contact-no$atSign_2:$value');
    String response = await sh2.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    assert(response.contains('data:delivered'));

    ///notify:list verb
    await sh1.writeCommand('notify:list');
    response = await sh1.read();
    print('notify list verb response : $response');
    expect(response,
        contains('"key":"$atSign_1:contact-no$atSign_2","value":null'));
  });

  test('notify verb without messageType', () async {
    /// NOTIFY VERB
    var value = '$lastValue-Hyderabad';
    await sh2.writeCommand(
        'notify:update:ttr:-1:$atSign_1:fav-city$atSign_2:$value');
    String response = await sh2.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    assert(response.contains('data:delivered'));

    ///notify:list verb
    await sh1.writeCommand('notify:list');
    response = await sh1.read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$atSign_1:fav-city$atSign_2","value":"$value","operation":"update"'));
  });

  test('notify verb for notifying a text update to another atsign', () async {
    //   /// NOTIFY VERB
    var value = '$lastValue-Hey,Hello!';
    await sh2.writeCommand(
        'notify:update:messageType:text:notifier:chat:ttr:-1:$atSign_1:$value');
    String response = await sh2.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    //   ///notify:list verb
    await sh1.writeCommand('notify:list');
    response = await sh1.read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$atSign_1:$value","value":null,"operation":"update"'));
  });

  test('notify verb for deleting a key for other atsign', () async {
    //   /// NOTIFY VERB
    await sh1.writeCommand(
        'notify:delete:messageType:key:notifier:system:ttr:-1:$atSign_2:email$atSign_1');
    String response = await sh1.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //  notify status
    response = await getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    //notify:list verb with regex
    await sh2.writeCommand('notify:list:email');
    response = await sh2.read();
    print('notify list verb response : $response');
    expect(
        response,
        contains(
            '"key":"$atSign_2:email$atSign_1","value":"null","operation":"delete"'));
  });

  test('notify verb without giving message type value', () async {
    /// NOTIFY VERB
    await sh1.writeCommand(
        'notify:update:messageType:notifier:system:ttr:-1:$atSign_2:email$atSign_1');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  });

  test('notify verb without giving notifier for strategy latest', () async {
    //   /// NOTIFY VERB
    await sh1.writeCommand(
        'notify:update:messageType:key:strategy:latest:ttr:-1:$atSign_2:email$atSign_1');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  });

  test('notify verb with messageType text', () async {
    //   /// NOTIFY VERB
    await sh1.writeCommand('notify:update:messageType:text:$atSign_2:Hello!');
    String response = await sh1.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with space in the value', () async {
     /// NOTIFY VERB
    var value = '$lastValue Shris Infotech Services';
    await sh1.writeCommand(
        'notify:update:messageType:key:$atSign_2:company$atSign_1:$value');
    String response = await sh1.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb with messageType text', () async {
    //   /// NOTIFY VERB
    await sh1.writeCommand('notify:update:messageType:text:$atSign_2:Hello!');
    String response = await sh1.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
  });

  test('notify verb in an incorrect order', () async {
    /// NOTIFY VERB
    await sh1.writeCommand(
        'notify:messageType:key:update:notifier:system:ttr:-1:$atSign_2:email$atSign_1');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert((response.contains('Invalid syntax')));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
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
  //   await sh2.writeCommand( 'notify:list:twitter');
  //   response = await read();
  //   print('notify list verb response : $response');
  //   expect(
  //       response,
  //       contains(
  //           '"key":"$secondAtsign:twitter$firstAtsign","value":"bob_G","operation":"update"'));
  // });

  test('notify all for notifying a single atsign ', () async {
    /// atSign1: notify atSign2 about something
    await sh1
        .writeCommand('notify:all:$atSign_2:whatsapp$atSign_1:+91-901291029');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    /// atSign2: notify:list verb with regex
    String shouldContain = '"key":"$atSign_2:whatsapp$atSign_1"';
    response = await retryCommandUntilMatchOrTimeout(
        sh2, 'notify:list:whatsapp', shouldContain, 15000);
    print('notify list verb response : $response');
    expect(response, contains(shouldContain));
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
  //   await sh2.writeCommand( 'notify:list:twitter');
  //   response = await read();
  //   print('notify list verb response : $response');
  //   expect(
  //       response,
  //       contains(
  //           '"key":"$secondAtsign:twitter$firstAtsign","value":"null","operation":"delete"'));
  // });

  test('notify verb with notification expiry for messageType key', () async {
    //   /// NOTIFY VERB
    int ttln = 11000;
    await sh2.writeCommand(
        'notify:update:messageType:key:ttln:$ttln:ttr:-1:$atSign_1:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    int willExpireAt = DateTime.now().millisecondsSinceEpoch + ttln;

    //   // notify status before ttln expiry time
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 10000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    // Wait until ttln has been reached
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now < willExpireAt) {
      await Future.delayed(Duration(milliseconds: willExpireAt - now));
    }

    /// notify status after ttln expiry time
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['expired'], timeOutMillis: 1000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  });

  test('notify verb with notification expiry for errored- invalid atsign',
      () async {
    //   /// NOTIFY VERB
    int ttln = 11000;
    await sh2.writeCommand(
        'notify:update:messageType:key:ttln:$ttln:ttr:-1:@xyz:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    int willExpireAt = DateTime.now().millisecondsSinceEpoch + ttln;

    // notify status before ttln expiry time
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['errored'], timeOutMillis: 10000);
    expect(response, contains('data:errored'));

    // Wait until ttln has been reached
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now < willExpireAt) {
      await Future.delayed(Duration(milliseconds: willExpireAt - now));
    }

    /// notify status after ttln expiry time
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['expired'], timeOutMillis: 1000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  },skip: 'Non existent atSign. Skipping the test for now to avoid connection issue');

  test('notify verb with notification expiry with messageType text', () async {
    //   /// NOTIFY VERB
    int ttln = 11000;
    await sh2.writeCommand(
        'notify:update:messageType:text:ttln:$ttln:ttr:-1:$atSign_1:Hello!');
    String response = await sh2.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    int willExpireAt = DateTime.now().millisecondsSinceEpoch + ttln;

    // notify status before ttln expiry time
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 10000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    // Wait until ttln has been reached
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now < willExpireAt) {
      await Future.delayed(Duration(milliseconds: willExpireAt - now));
    }

    /// notify status after ttln expiry time
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['expired'], timeOutMillis: 1000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  });

  ///
  test('notify verb with notification expiry in an incorrect spelling',
      () async {
    //   /// NOTIFY VERB
    await sh2.writeCommand(
        'notify:update:ttlnn:5000:ttr:-1:$atSign_1:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh2.close();
    sh2 = await e2e.getSocketHandler(atSign_1);
  });

  test('notify verb with notification expiry without value for ttln', () async {
    //   /// NOTIFY VERB
    await sh2.writeCommand(
        'notify:update:ttln:ttr:-1:$atSign_1:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh2.close();
    sh2 = await e2e.getSocketHandler(atSign_1);
  });

  test('notify verb with notification expiry in an incorrect order', () async {
    //   /// NOTIFY VERB
    await sh2.writeCommand(
        'notify:update:ttb:3000:ttr:-1:ttln:10000:$atSign_1:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  });

  test(
      'notify a key and verifying the time taken for the status to be delivered',
      () async {
    var timeBeforeNotification = DateTime.now().millisecondsSinceEpoch;
    await sh1.writeCommand(
        'notify:update:messageType:key:$atSign_2:company$atSign_1:atsign');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // notify status
    response = await getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));
    var timeAfterNotification = DateTime.now().millisecondsSinceEpoch;
    var timeDifferenceValue =
        DateTime.fromMillisecondsSinceEpoch(timeAfterNotification).difference(
            DateTime.fromMillisecondsSinceEpoch(timeBeforeNotification));
    print('time difference is $timeDifferenceValue');
    expect(timeDifferenceValue.inMilliseconds <= 10000, true);
  });
// commenting till server code is released to prod
//  test('notify verb for notifying a key update with shared key metadata',
//      () async {
//    /// NOTIFY VERB
//    await sh1.writeCommand(
//        'notify:update:messageType:key:notifier:SYSTEM:ttln:86400000:ttr:60000:ccd:false:sharedKeyEnc:abc:pubKeyCS:3c55db695d94b304827367a4f5cab8ae:$atSign_2:phone.wavi$atSign_1:E5skXtdiGbEJ9nY6Kvl+UA==');
//    String response = await sh1.read();
//    print('notify verb response : $response');
//    assert(
//        (!response.contains('Invalid syntax')) && (!response.contains('null')));
//    String notificationId = response.replaceAll('data:', '');
//
//    // notify status
//    response = await getNotifyStatus(sh1, notificationId,
//        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
//    print('notify status response : $response');
//    expect(response, contains('data:delivered'));
//
//    ///notify:list verb
//    await sh2.writeCommand('llookup:all:cached:$atSign_2:phone.wavi$atSign_1');
//    response = await sh2.read();
//    print('llookup verb response : $response');
//    expect(
//        response,
//        contains(
//            '"key":"cached:$atSign_2:phone.wavi@$atSign_1","value":"E5skXtdiGbEJ9nY6Kvl+UA==","sharedKeyEnc":"abc", "pubKeyCS":"3c55db695d94b304827367a4f5cab8ae"'));
//  });
}

// get notify status
Future<String> getNotifyStatus(
    e2e.SimpleOutboundSocketHandler sh, String notificationId,
    {List<String>? returnWhenStatusIn, int timeOutMillis = 5000}) async {
  returnWhenStatusIn ??= ['expired'];
  print(
      "getNotifyStatus will check for notify:status response in '$returnWhenStatusIn' for $timeOutMillis");

  int loopDelay = 1000;

  String response = 'NO_RESPONSE';

  bool readTimedOut = false;
  int endTime = DateTime.now().millisecondsSinceEpoch + timeOutMillis;
  while (DateTime.now().millisecondsSinceEpoch < endTime) {
    await Future.delayed(Duration(milliseconds: loopDelay));

    if (!readTimedOut) {
      await sh.writeCommand('notify:status:$notificationId', log: true);
    }
    response = await sh.read(
        log: true, timeoutMillis: loopDelay, throwTimeoutException: false);

    readTimedOut =
        (response == e2e.SimpleOutboundSocketHandler.readTimedOutMessage);

    if (response.startsWith('data:')) {
      String status = response.replaceFirst('data:', '').replaceAll('\n', '');
      if (returnWhenStatusIn.contains(status)) {
        break;
      }
    }
  }

  print(
      "getNotifyStatus return with response $response (was waiting for '$returnWhenStatusIn')");

  return response;
}

Future<String> retryCommandUntilMatchOrTimeout(
    e2e.SimpleOutboundSocketHandler sh,
    String command,
    String shouldContain,
    int timeoutMillis) async {
  int loopDelay = 1000;

  String response = 'NO_RESPONSE';

  bool readTimedOut = false;
  int endTime = DateTime.now().millisecondsSinceEpoch + timeoutMillis;
  while (DateTime.now().millisecondsSinceEpoch < endTime) {
    await Future.delayed(Duration(milliseconds: loopDelay));

    if (!readTimedOut) {
      await sh.writeCommand(command, log: true);
    }

    response = await sh.read(
        log: false, timeoutMillis: loopDelay, throwTimeoutException: false);

    readTimedOut =
        (response == e2e.SimpleOutboundSocketHandler.readTimedOutMessage);
    if (readTimedOut) {
      continue;
    }

    if (response.contains(shouldContain)) {
      print("Got response, contained $shouldContain");
      break;
    }
    print("Got response, didn't contain $shouldContain");
  }

  return response;
}
