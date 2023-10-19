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

  var lastValue = Random().nextInt(30);

  late Version atSign1ServerVersion;
  late Version atSign2ServerVersion;

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();

    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign1ServerVersion = Version.parse(await sh1.getVersion());

    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);
    atSign2ServerVersion = Version.parse(await sh2.getVersion());
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
    if (atSign1ServerVersion > Version(3, 0, 23)) {
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

    // notify:list
    await sh2.writeCommand('notify:list');
    response = await sh2.read();
    expect(
        response.contains(
            '"key":"$atSign_2:city.me$atSign_1","value":"$value","operation":"update"'),
        true);
  });

  test('notify verb without messageType and operation', () async {
    /// NOTIFY VERB
    var value = '+91-901282346$lastValue';
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
    if (atSign2ServerVersion > Version(3, 0, 35)) {
      await sh1.writeCommand('notify:list');
      response = await sh1.read();
      print('notify list verb response : $response');
      expect(response,
          contains('"key":"$atSign_1:contact-no$atSign_2","value":"$value'));
    }
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

    ///notify:list verb
    await sh1.writeCommand('notify:list');
    response = await sh1.read();
    print('notify list verb response : $response');
    expect(response,
        contains('"key":"$atSign_1:$value","value":null,"operation":"update"'));
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
    if (atSign1ServerVersion > Version(3, 0, 35)) {
      expect(
          response,
          contains(
              '"key":"$atSign_2:email$atSign_1","value":null,"operation":"delete"'));
    }
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

    String keyRequired =
        '"key":"$atSign_2:Hello!","value":null,"operation":"update"';
    response = await retryCommandUntilMatchOrTimeout(
        sh2, 'notify:list', keyRequired, 15000);
    print('notify list response for text $response');
    expect(response, contains(keyRequired));
  });

  test('notify verb with space in the value', () async {
    /// NOTIFY VERB
    var value = '$lastValue Shris Infotech Services';
    await sh1.writeCommand(
        'notify:update:messageType:key:ttr:-1:$atSign_2:company$atSign_1:$value');
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

    // notify:list
    String keyRequired =
        '"key":"$atSign_2:company$atSign_1","value":"$value","operation":"update"';
    response = await retryCommandUntilMatchOrTimeout(
        sh2, 'notify:list:company', keyRequired, 15000);
    print('notify list response $response');
    expect(response, contains(keyRequired));
  });

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

  test('notify verb with notification expiry for messageType key', () async {
    //   /// NOTIFY VERB
    int ttln = 11000;
    await sh2.writeCommand(
        'notify:update:messageType:key:ttln:$ttln:ttr:-1:$atSign_2:message$atSign_2:Hey!');
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

    // check that notification doesn't exist in other atsign after expiry
    await sh1.writeCommand('notify:list:message');
    response = await sh1.read();
    expect(
        response.contains(
            '"key":"$atSign_2:message$atSign_1","value":"hey how are you?","operation":"update"'),
        false);
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
        returnWhenStatusIn: ['expired'], timeOutMillis: 5000);
    print('notify status response : $response');
    expect(response, contains('data:expired'));
  });

  // this test needs an notification to be sent to another atsign
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

  test('Test to verify the update and delete caching of key', () async {
    var key = 'testcachedkey-$lastValue';
    // Sending the update notification from the sender side
    await sh1.writeCommand(
        'notify:update:ttr:10000:ccd:true:$atSign_2:$key$atSign_1:cachedvalue-$lastValue');
    var response = await sh1.read();
    response = response.replaceAll('data:', '');
    // assert the notification-id is not null.
    assert(response.isNotEmpty);

    await Future.delayed(Duration(seconds: 1));
    // fetch the notification for status
    await sh1.writeCommand('notify:fetch:$response');
    response = await sh1.read();
    response = response.replaceAll('data:', '');
    var decodedJSON = jsonDecode(response);
    expect(decodedJSON['fromAtSign'], atSign_1);
    expect(decodedJSON['toAtSign'], atSign_2);
    expect(decodedJSON['notification'], '$atSign_2:$key$atSign_1');
    expect(decodedJSON['type'], 'NotificationType.sent');
    expect(decodedJSON['opType'], 'OperationType.update');
    expect(decodedJSON['messageType'], 'MessageType.key');
    expect(decodedJSON['notificationStatus'], 'NotificationStatus.delivered');

    // Look for the value of the cached key on  the receiver atSign
    await sh2.writeCommand('llookup:cached:$atSign_2:$key$atSign_1');
    response = await sh2.read();
    expect(response, 'data:cachedvalue-$lastValue');

    // Send the delete notification from the sender side
    await sh1.writeCommand('notify:delete:$atSign_2:$key$atSign_1');
    response = await sh1.read();
    assert(response.isNotEmpty);

    await Future.delayed(Duration(seconds: 1));

    // Look for the delete of the cached key
    await sh2.writeCommand('llookup:cached:$atSign_2:$key$atSign_1');
    response = await sh2.read();
    response = response.replaceAll('error:', '');
    decodedJSON = jsonDecode(response);
    expect(decodedJSON['errorCode'], 'AT0015');
    expect(decodedJSON['errorDescription'], contains('key not found'));
  });

  test(
      'notify a key and verifying the time taken for the status to be delivered',
      () async {
    var timeBeforeNotification = DateTime.now().millisecondsSinceEpoch;
    String value = 'AtSign Company';
    await sh1.writeCommand(
        'notify:update:messageType:key:ttr:-1:$atSign_2:organisation.wavi$atSign_1:$value');
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

    // notify:list
    String keyRequired =
        '"key":"$atSign_2:organisation.wavi$atSign_1","value":"$value","operation":"update"';
    response = await retryCommandUntilMatchOrTimeout(
        sh2, 'notify:list:organisation', keyRequired, 15000);
    expect(response, contains(keyRequired));
  });

  /// The purpose of this test is verify the date time of second notification is correct
  /// not picked from the earlier notification.
  test('A test to verify subsequent notifications has correct date', () async {
    // Sending first notification
    await sh1.writeCommand('notify:$atSign_2:firstNotification$atSign_1');
    var notificationIdFromAtSign1 = (await sh1.read()).replaceAll('data:', '');

    // Wait for delivered status
    var deliveryStatus = await getNotifyStatus(sh1, notificationIdFromAtSign1,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response, first notification : $deliveryStatus');
    expect(deliveryStatus, contains('data:delivered'));

    await sh2.writeCommand('notify:fetch:$notificationIdFromAtSign1');
    var notificationIdFromAtSign2 = (await sh2.read()).replaceAll('data:', '');
    var atNotificationMap = jsonDecode(notificationIdFromAtSign2);
    var firstNotificationDateInEpoch =
        DateTime.parse(atNotificationMap['notificationDateTime'])
            .microsecondsSinceEpoch;

    // Sending second notification
    await sh1.writeCommand('notify:$atSign_2:secondNotification$atSign_1');
    notificationIdFromAtSign1 = (await sh1.read()).replaceAll('data:', '');

    // Wait for delivered status
    deliveryStatus = await getNotifyStatus(sh1, notificationIdFromAtSign1,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    print('notify status response, second notification : $deliveryStatus');
    expect(deliveryStatus, contains('data:delivered'));

    await sh2.writeCommand('notify:fetch:$notificationIdFromAtSign1');
    notificationIdFromAtSign2 = (await sh2.read()).replaceAll('data:', '');
    atNotificationMap = jsonDecode(notificationIdFromAtSign2);
    var secondNotificationDateInEpoch =
        DateTime.parse(atNotificationMap['notificationDateTime'])
            .microsecondsSinceEpoch;

    expect(secondNotificationDateInEpoch > firstNotificationDateInEpoch, true);
  });

  test('notify verb for notifying a key update with shared key metadata',
      () async {
    /// NOTIFY VERB
    await sh1.writeCommand('notify:update:messageType:key:notifier:SYSTEM'
        ':ttln:86400000:ttr:60000:ccd:false'
        ':sharedKeyEnc:abc:pubKeyCS:3c55db695d94b304827367a4f5cab8ae'
        ':$atSign_2:phone.wavi$atSign_1:Some ciphertext');
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
    expect(decodedResponse['data'], 'Some ciphertext');
    expect(decodedResponse['metaData']['sharedKeyEnc'], 'abc');
    expect(decodedResponse['metaData']['pubKeyCS'],
        '3c55db695d94b304827367a4f5cab8ae');
    expect(decodedResponse['metaData']['ttr'], 60000);
  });

  test('notify verb for notifying a key update with new encryption metadata',
      () async {
    /// NOTIFY VERB
    var sharedKeyEnc = 'abc';
    var pubKeyCS = '3c55db695d94b304827367a4f5cab8ae';
    var encKeyName = 'someEncKeyName';
    var encAlgo = 'AES/CTR/PKCS7Padding';
    var iv = 'anInitializationVector';
    var skeEncKeyName = 'someSkeEncKeyName';
    var skeEncAlgo = 'RSA-2048';
    var ttln = 60 * 1000; // 60 seconds

    if (atSign1ServerVersion < Version(3, 0, 29)) {
      // Server version 3.0.28 or earlier will not process new metadata
      // No point in trying to send anything
      return;
    }

    await sh1.writeCommand('notify:update'
        ':messageType:key'
        ':notifier:SYSTEM'
        ':ttln:$ttln'
        ':ttr:10'
        ':ccd:false'
        ':sharedKeyEnc:$sharedKeyEnc'
        ':pubKeyCS:$pubKeyCS'
        ':encKeyName:$encKeyName'
        ':encAlgo:$encAlgo'
        ':ivNonce:$iv'
        ':skeEncKeyName:$skeEncKeyName'
        ':skeEncAlgo:$skeEncAlgo'
        ':$atSign_2:phone.wavi$atSign_1'
        ':Some ciphertext');
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
    expect(decodedResponse['data'], 'Some ciphertext');
    expect(decodedResponse['metaData']['sharedKeyEnc'], sharedKeyEnc);
    expect(decodedResponse['metaData']['pubKeyCS'], pubKeyCS);
    expect(decodedResponse['metaData']['ttr'], 10);

    if (atSign2ServerVersion > Version(3, 0, 28)) {
      expect(decodedResponse['metaData']['encKeyName'], encKeyName);
      expect(decodedResponse['metaData']['encAlgo'], encAlgo);
      expect(decodedResponse['metaData']['ivNonce'], iv);
      expect(decodedResponse['metaData']['skeEncKeyName'], skeEncKeyName);
      expect(decodedResponse['metaData']['skeEncAlgo'], skeEncAlgo);
    } else {
      expect(decodedResponse['metaData']['encKeyName'], null);
      expect(decodedResponse['metaData']['encAlgo'], null);
      expect(decodedResponse['metaData']['ivNonce'], null);
      expect(decodedResponse['metaData']['skeEncKeyName'], null);
      expect(decodedResponse['metaData']['skeEncAlgo'], null);
    }
  });

  group('A group of tests related to notify ephemeral', () {
    test(
        'notify verb without ttr for messageType-key and operation type - update and with value',
        () async {
      // The notify ephemeral changes are not into Canary and production.
      // So, no point in running against and Canary and Prod servers.`
      if (atSign2ServerVersion < Version(3, 0, 36)) {
        return;
      }

      /// NOTIFY VERB
      var value = 'testingvalue';
      await sh2.writeCommand(
          'notify:update:messageType:key:$atSign_1:testkey$atSign_2:$value');
      String response = await sh2.read();
      print('notify verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
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
              '"key":"$atSign_1:testkey$atSign_2","value":"$value","operation":"update"'));
    });

    test('notify verb without ttr and without value for operation type update',
        () async {
      // The notify ephemeral changes are not into Canary and production.
      // So, no point in running against and Canary and Prod servers.`
      if (atSign2ServerVersion < Version(3, 0, 36)) {
        return;
      }

      /// NOTIFY VERB
      await sh2.writeCommand('notify:update:$atSign_1:nottrkey$atSign_2');
      String response = await sh2.read();
      print('notify verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
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
              '"key":"$atSign_1:nottrkey$atSign_2","value":null,"operation":"update"'));
    });

    test(
        'notify verb without ttr for messageType-text and operation type - update',
        () async {
      // The notify ephemeral changes are not into Canary and production.
      // So, no point in running against and Canary and Prod servers.`
      if (atSign2ServerVersion < Version(3, 0, 36)) {
        return;
      }

      /// NOTIFY VERB
      await sh2.writeCommand(
          'notify:update:messageType:text:$atSign_1:hello_world$atSign_2');
      String response = await sh2.read();
      print('notify verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
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
              '"key":"$atSign_1:hello_world","value":null,"operation":"update"'));
    });

    test(
        'notify verb without ttr for messageType-text and operation type - delete',
        () async {
      // The notify ephemeral changes are not into Canary and production.
      // So, no point in running against and Canary and Prod servers.`
      if (atSign2ServerVersion < Version(3, 0, 36)) {
        return;
      }

      /// NOTIFY VERB
      await sh2.writeCommand(
          'notify:delete:messageType:text:$atSign_1:hello_world$atSign_2');
      String response = await sh2.read();
      print('notify verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
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
              '"key":"$atSign_1:hello_world","value":null,"operation":"delete"'));
    });

    test('notify verb without ttr for operation type delete', () async {
      // The notify ephemeral changes are not into Canary and production.
      // So, no point in running against and Canary and Prod servers.`
      if (atSign2ServerVersion < Version(3, 0, 36)) {
        return;
      }

      /// NOTIFY VERB
      await sh2.writeCommand('notify:delete:$atSign_1:twitter-id$atSign_2');
      String response = await sh2.read();
      print('notify verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
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
              '"key":"$atSign_1:twitter-id$atSign_2","value":null,"operation":"delete"'));
    });
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
