import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:version/version.dart';

import 'e2e_test_utils.dart' as e2e;

void main() {
  late String atSign_1;
  late e2e.SimpleOutboundSocketHandler sh1;

  late String atSign_2;
  late e2e.SimpleOutboundSocketHandler sh2;

  var randomValue = Random().nextInt(30);

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

  test('notify verb for notifying a key update to the atSign', () async {
    /// NOTIFY VERB
    var value = 'alice$randomValue@yahoo.com';
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

    ///Assert the notification data on the sender side using notify fetch
    await sh2.writeCommand('notify:fetch:$notificationId');
    response = await sh2.read();
    response = response.replaceAll('data:', '');
    var notificationJSON = jsonDecode(response);
    expect(notificationJSON['id'], notificationId);
    expect(notificationJSON['fromAtSign'], atSign_2);
    expect(notificationJSON['toAtSign'], atSign_1);
    // TODO: Remove version check after 3.0.28 version is released to production.
    var serverResponse = Version.parse(await sh2.getVersion());
    if (serverResponse > Version(3, 0, 27)) {
      expect(notificationJSON['notification'], 'email');
    } else {
      expect(notificationJSON['notification'], '$atSign_1:email$atSign_2');
    }
    expect(notificationJSON['type'], 'NotificationType.sent');
    expect(notificationJSON['opType'], 'OperationType.update');
    expect(notificationJSON['messageType'], 'MessageType.key');
    expect(notificationJSON['priority'], 'NotificationPriority.low');

    ///Assert the notification data on the receiver side using notify fetch
    await sh1.writeCommand('notify:fetch:$notificationId');
    response = await sh1.read();
    response = response.replaceAll('data:', '');
    notificationJSON = jsonDecode(response);
    expect(notificationJSON['id'], notificationId);
    expect(notificationJSON['fromAtSign'], atSign_2);
    expect(notificationJSON['toAtSign'], atSign_1);
    // TODO: Remove version check after 3.0.28 version is released to production.
    serverResponse = Version.parse(await sh1.getVersion());
    if (serverResponse > Version(3, 0, 27)) {
      expect(notificationJSON['notification'], 'email');
    } else {
      expect(notificationJSON['notification'], '$atSign_1:email$atSign_2');
    }
    expect(notificationJSON['type'], 'NotificationType.received');
    expect(notificationJSON['opType'], 'OperationType.update');
    expect(notificationJSON['messageType'], 'MessageType.key');
    expect(notificationJSON['priority'], 'NotificationPriority.low');
    expect(notificationJSON['atValue'], 'alice$randomValue@yahoo.com');
  });

  test('test to verify notify fetch verb for a valid notification-id',
      () async {
    /// NOTIFY VERB
    var value = 'Copenhagen';
    await sh1.writeCommand(
        'notify:update:messageType:key:notifier:system:ttr:-1:$atSign_2:city.me$atSign_1:$value');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // Assert notification status
    response = await getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    // Fetch notification
    var serverResponse = Version.parse(await sh1.getVersion());
    if (serverResponse > Version(3, 0, 23)) {
      await sh1.writeCommand('notify:fetch:$notificationId');
      response = await sh1.read();
      response = response.replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId);
      expect(atNotificationMap['fromAtSign'], atSign_1);
      expect(atNotificationMap['toAtSign'], atSign_2);
      expect(atNotificationMap['type'], 'NotificationType.sent');
      expect(atNotificationMap['notificationStatus'],
          'NotificationStatus.delivered');
    }
  });

  test('notify verb without messageType and operation', () async {
    /// NOTIFY VERB
    var value = '+91-901282346$randomValue';
    await sh2.writeCommand('notify:$atSign_1:contact-no$atSign_2:$value');
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
    // TODO: Remove version check after 3.0.28 version is released to production.
    var serverResponse = Version.parse(await sh1.getVersion());
    if (serverResponse > Version(3, 0, 27)) {
      expect(response, contains('"key":"contact-no","value":null'));
    } else {
      expect(response, contains('"key":"$atSign_1:contact-no$atSign_2"'));
    }
  });

  test('notify verb without messageType', () async {
    /// NOTIFY VERB
    var value = '$randomValue-Hyderabad';
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
    // TODO: Remove version check after 3.0.28 version is released to production.
    var serverResponse = Version.parse(await sh1.getVersion());
    if (serverResponse > Version(3, 0, 27)) {
      expect(response,
          contains('"key":"fav-city","value":"$value","operation":"update"'));
    } else {
      expect(
          response,
          contains(
              '"key":"$atSign_1:fav-city$atSign_2","value":"$value","operation":"update"'));
    }
  });

  test('notify verb for notifying a text update to another atSign', () async {
    // Send the notification of type "text"
    var value = '$randomValue-Hey,Hello!';
    await sh2.writeCommand(
        'notify:update:messageType:text:notifier:chat:ttr:-1:$atSign_1:$value');
    String response = await sh2.read();
    print('notify verb response : $response');
    String notificationId = response.replaceAll('data:', '');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    // Assert the notification status on the sender side.
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    // Assert the notification status on the receiver side.
    await sh1.writeCommand('notify:fetch:$notificationId');
    response = await sh1.read();
    print('notify list verb response : $response');
    response = response.replaceAll('data:', '');
    var notificationJSON = jsonDecode(response);
    expect(notificationJSON['id'], notificationId);
    expect(notificationJSON['fromAtSign'], atSign_2);
    expect(notificationJSON['toAtSign'], atSign_1);
    // TODO: Remove version check after 3.0.28 version is released to production.
    var serverResponse = Version.parse(await sh1.getVersion());
    if (serverResponse > Version(3, 0, 27)) {
      expect(notificationJSON['notification'], value);
    } else {
      expect(notificationJSON['notification'], '$atSign_1:$value');
    }
    expect(notificationJSON['type'], 'NotificationType.received');
    expect(notificationJSON['opType'], 'OperationType.update');
    expect(notificationJSON['messageType'], 'MessageType.text');
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
    //TODO: Remove version check after 3.0.28 version is released to production.
    var serverResponse = Version.parse(await sh2.getVersion());
    if (serverResponse > Version(3, 0, 27)) {
      expect(response,
          contains('"key":"email","value":"null","operation":"delete"'));
    } else {
      expect(response, contains('"key":"@cicd4:email@cicd3"'));
    }
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
    // Notify verb
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
    // Notify verb
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
    // Notify verb
    var value = '$randomValue Shris Infotech Services';
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

  test('notify verb in an incorrect order', () async {
    // Notify verb - incorrect order of messageType and update.
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
    // atSign1: notify atSign2 about something
    await sh1
        .writeCommand('notify:all:$atSign_2:whatsapp$atSign_1:+91-901291029');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // atSign2: notify:list verb with regex
    String shouldContain = '"key":"whatsapp"';
    response = await retryCommandUntilMatchOrTimeout(
        sh2, 'notify:list:whatsapp', shouldContain, 15000);
    print('notify list verb response : $response');
    expect(response, contains('whatsapp'));
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
    // Notify verb
    int ttln = 11000;
    await sh2.writeCommand(
        'notify:update:messageType:key:ttln:$ttln:ttr:-1:$atSign_1:message$atSign_2:Hey!');
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

    // notify status after ttln expiry time
    response = await getNotifyStatus(sh2, notificationId,
        returnWhenStatusIn: ['expired'], timeOutMillis: 1000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  });

  test('notify verb with notification expiry for errored- invalid atsign',
      () async {
    // NOTIFY VERB
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
  });

  test('notify verb with notification expiry with messageType text', () async {
    // Notify verb
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

  test('notify verb with notification expiry in an incorrect spelling',
      () async {
    // Notify verb
    await sh2.writeCommand(
        'notify:update:ttlnn:5000:ttr:-1:$atSign_1:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh2.close();
    sh2 = await e2e.getSocketHandler(atSign_2);
  });

  test('Test to verify the update and delete caching of key', () async {
    var key = 'testcachedkey-$randomValue';
    // Sending the update notification from the sender side
    await sh1.writeCommand(
        'notify:update:ttr:10000:ccd:true:$atSign_2:$key$atSign_1:cachedvalue-$randomValue');
    var response = await sh1.read();
    response = response.replaceAll('data:', '');
    // assert the notification-id is not null.
    assert(response.isNotEmpty);
    // fetch the notification for status
    await sh1.writeCommand('notify:fetch:$response');
    response = await sh1.read();
    response = response.replaceAll('data:', '');
    var decodedJSON = jsonDecode(response);
    expect(decodedJSON['fromAtSign'], atSign_1);
    expect(decodedJSON['toAtSign'], atSign_2);
    // TODO: Remove version check after 3.0.28 version is released to production.
    var serverResponse = Version.parse(await sh1.getVersion());
    if (serverResponse > Version(3, 0, 27)) {
      expect(decodedJSON['notification'], key);
    } else {
      expect(decodedJSON['notification'], '$atSign_2:$key$atSign_1');
    }
    expect(decodedJSON['type'], 'NotificationType.sent');
    expect(decodedJSON['opType'], 'OperationType.update');
    expect(decodedJSON['messageType'], 'MessageType.key');
    expect(decodedJSON['notificationStatus'], 'NotificationStatus.delivered');

    // Look for the value of the cached key on  the receiver atSign
    await sh2.writeCommand('llookup:cached:$atSign_2:$key$atSign_1');
    response = await sh2.read();
    expect(response, 'data:cachedvalue-$randomValue');

    // Send the delete notification from the sender side
    await sh1.writeCommand('notify:delete:$atSign_2:$key$atSign_1');
    response = await sh1.read();
    assert(response.isNotEmpty);

    // Look for the delete of the cached key
    await sh2.writeCommand('llookup:cached:$atSign_2:$key$atSign_1');
    response = await sh2.read();
    response = response.replaceAll('error:', '');
    decodedJSON = jsonDecode(response);
    expect(decodedJSON['errorCode'], 'AT0015');
    expect(decodedJSON['errorDescription'], contains('key not found'));
  });

  test('notify verb with notification expiry without value for ttln', () async {
    // Notify verb
    await sh2.writeCommand(
        'notify:update:ttln:ttr:-1:$atSign_1:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh2.close();
    sh2 = await e2e.getSocketHandler(atSign_2);
  });

  test('notify verb with notification expiry in an incorrect order', () async {
    // Notify verb - Incorrect order of metadata. ttln should be before ttb and ttr
    await sh2.writeCommand(
        'notify:update:ttb:3000:ttr:-1:ttln:10000:$atSign_1:message$atSign_2:Hey!');
    String response = await sh2.read();
    print('notify verb response : $response');
    expect(response, contains('Invalid syntax'));
    // Invalid syntax results in a closed connection so let's do some housekeeping
    sh2.close();
    sh2 = await e2e.getSocketHandler(atSign_2);
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

  /// The purpose of this test is verify the date time of second notification is correct
  /// not picked from the earlier notification.
  test('A test to verify subsequent notifications has correct date', () async {
    // Sending first notification
    await sh1.writeCommand('notify:$atSign_2:firstNotification$atSign_1');
    var response = await sh1.read();
    var currentDateTime = DateTime.now();
    // Sending second notification
    await sh1.writeCommand('notify:$atSign_2:secondNotification$atSign_1');
    response = await sh1.read();
    response = response.replaceAll('data:', '');
    await sh2.writeCommand('notify:fetch:$response');
    response = await sh2.read();
    response = response.replaceAll('data:', '');
    var atNotificationMap = jsonDecode(response);
    expect(
        DateTime.parse(atNotificationMap['notificationDateTime'])
                .microsecondsSinceEpoch >
            currentDateTime.microsecondsSinceEpoch,
        true);
  });

  test('notify verb for notifying a key update with shared key metadata',
      () async {
    /// NOTIFY VERB
    await sh1.writeCommand(
        'notify:update:messageType:key:notifier:SYSTEM:ttln:86400000:ttr:60000:ccd:false:sharedKeyEnc:abc:pubKeyCS:3c55db695d94b304827367a4f5cab8ae:$atSign_2:phone.wavi$atSign_1:E5skXtdiGbEJ9nY6Kvl+UA==');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');

    // notify status
    response = await getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response : $response');
    expect(response, contains('data:delivered'));

    await sh2.writeCommand('llookup:all:cached:$atSign_2:phone.wavi$atSign_1');
    response = await sh2.read();
    response = response.replaceAll('data:', '');
    var decodedResponse = jsonDecode(response);
    expect(decodedResponse['key'], 'cached:$atSign_2:phone.wavi$atSign_1');
    expect(decodedResponse['data'], 'E5skXtdiGbEJ9nY6Kvl+UA==');
    expect(decodedResponse['metaData']['sharedKeyEnc'], 'abc');
    expect(decodedResponse['metaData']['pubKeyCS'],
        '3c55db695d94b304827367a4f5cab8ae');
    expect(decodedResponse['metaData']['ttr'], 60000);
  });
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
