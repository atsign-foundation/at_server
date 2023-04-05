import 'dart:convert';

import 'package:test/test.dart';
import 'notify_verb_test.dart' as notification;
import 'e2e_test_utils.dart' as e2e;

void main() {
  late String atSign_1;
  late e2e.SimpleOutboundSocketHandler sh1;

  late String atSign_2;
  late e2e.SimpleOutboundSocketHandler sh2;

  int lastValue = DateTime.now().millisecondsSinceEpoch;

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

  test('update-llookup verb with ttr:-1', () async {
    // TODO Remove this when https://github.com/atsign-foundation/at_server/pull/664 has been included in a production release
    if ('@cicd5' == atSign_1) {
      expect(true, true);
      return;
    }

    /// UPDATE VERB
    var value = 'val-ttr--1-$lastValue';
    await sh1.writeCommand(
        'notify:update:ttl:600000:ttr:-1:$atSign_2:key-1$atSign_1:$value');
    String response = await sh1.read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 60000);

    ///LLOOKUP VERB in the receiving atsign
    await Future.delayed(Duration(seconds: 2));
    await sh2.writeCommand('llookup:cached:$atSign_2:key-1$atSign_1');
    response = await sh2.read();
    print('llookup verb response of a cached key : $response');
    expect(response, contains('data:$value'));
  }, timeout: Timeout(Duration(seconds: 100)));

  test('update-llookup verb with ttr and ccd true', () async {
    /// UPDATE VERB
    var value = 'val-ttr-ccd-true-$lastValue';
    await sh1.writeCommand(
        'notify:update:ttl:15000:ttr:2000:ccd:true:$atSign_2:key-2$atSign_1:$value');
    var response = await sh1.read(timeoutMillis: 1000);
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 20000);

    ///LLOOKUP VERB in the receiving atsign before delete
    await sh2.writeCommand('llookup:cached:$atSign_2:key-2$atSign_1');
    response = await sh2.read();
    print('llookup verb response of a cached key before delete : $response');
    expect(response, contains('data:$value'));

    /// Deleting key which has ccd:true
    await sh1.writeCommand('notify:delete:$atSign_2:key-2$atSign_1');
    response = await sh1.read();
    print('notify delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 20000);

    ///LLOOKUP VERB in the receiving atsign after deleting the key from the sender
    await sh2.writeCommand('llookup:cached:$atSign_2:key-2$atSign_1');
    response = await sh2.read();
    print('llookup verb response of a cached key : $response');
    expect(response,
        contains('cached:$atSign_2:key-2$atSign_1 does not exist in keystore'));
  }, timeout: Timeout(Duration(seconds: 100)));

  test('update-llookup verb with ttr and ccd false', () async {
    /// UPDATE VERB
    var value = 'val-ttr-ccd-false-$lastValue';
    await sh1.writeCommand(
        'notify:update:ttl:15000:ttr:2000:ccd:false:$atSign_2:key-3$atSign_1:$value');
    var response = await sh1.read(timeoutMillis: 1000);
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 20000);

    ///LLOOKUP VERB in the receiving atsign before delete
    await sh2.writeCommand('llookup:cached:$atSign_2:key-3$atSign_1');
    response = await sh2.read();
    print('llookup verb response of a cached key before delete : $response');
    expect(response, contains('data:$value'));

    /// Deleting key which has ccd:true
    await sh1.writeCommand('notify:delete:$atSign_2:key-3$atSign_1');
    response = await sh1.read();
    print('delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 20000);

    ///LLOOKUP VERB in the receiving atsign after deleting the key from the sender
    await sh2.writeCommand('llookup:cached:$atSign_2:key-3$atSign_1');
    response = await sh2.read();
    print('llookup verb response of a cached key : $response');
    expect(response, contains('data:$value'));
  }, timeout: Timeout(Duration(seconds: 100)));

  /// The purpose of this test verify the following:
  /// 1. Share a key from atsign_1 to atsign_2 with ttr, with autoNotify:true
  /// 2. lookup from atsign_2 returns the correct value
  /// 3.  Set the autoNotify to false using the config verb
  /// 4. Update the existing key to a new value
  /// 5. lookup with bypass_cache set to false should return the old value from the cache
  /// 6. lookup with bypass_cache set to true should return the new value
  try {
    test('update-lookup verb passing bypassCache ', () async {
      ///Update verb on atsign_1
      // Check if TestingMode is enabled on the secondary server
      // If yes allow the test to run, else skip
      await sh1.writeCommand('config:print:autoNotify\n');
      String response = await sh1.read();
      // If the autoNotify response is either data:true or data:false, then testingMode
      // is enabled; else, testingMode is NOT enabled on the secondary server
      // So, do not run the test when testingMode is disabled.
      if (!(response == 'data:true' || response == 'data:false')) {
        print(
            'Testing mode is not enabled on the secondary server: $atSign_1. So skipping the test');
        return;
      }

      try {
        var oldValue = 'Hyderabad';
        await sh1.writeCommand(
            'update:ttr:100000:$atSign_2:fav-city$atSign_1  $oldValue');
        response = await sh1.read();
        print('update verb response : $response');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));

        // Wait a few seconds to make sure the message has got to atSign_2
        await Future.delayed(Duration(seconds: 3));

        ///lookup verb alice  atsign_2
        await sh2.writeCommand('lookup:fav-city$atSign_1');
        response = await sh2.read();
        print('lookup verb response : $response');
        expect(response, contains('data: $oldValue'));

        // config set auto notify to false
        await sh1.writeCommand('config:set:autoNotify=false');
        response = await sh1.read();
        print('config set verb response is $response');
        expect(response, contains('data:ok'));

        var newValue = 'Chennai';
        await sh1.writeCommand('update:$atSign_2:fav-city$atSign_1  $newValue');
        response = await sh1.read();
        print('update verb response : $response');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));

        ///lookup with bypassCache:false (the default) should return the old value
        await sh2.writeCommand('lookup:fav-city$atSign_1');
        response = await sh2.read();
        print('lookup verb response : $response');
        expect(response, contains('data: $oldValue'));

        /// lookup with bypass_cache set to true
        /// should return the newly updated value
        await sh2.writeCommand('lookup:bypassCache:true:fav-city$atSign_1');
        response = await sh2.read();
        print('lookup verb response : $response');
        expect(response, contains('data: $newValue'));
      } finally {
        await sh1.writeCommand('config:reset:autoNotify');
        var response = await sh1.read();
        print('config set verb response is $response');
        expect(response, contains('data:ok'));
      }
    });
  } catch (e, s) {
    print(s);
  }

  test('test to verify update and delete of cached key via update-delete verb',
      () async {
    // Run update verb to cache key
    var key = 'cachedkeytest-$lastValue';
    var value = 'cached-value-$lastValue';

    await sh1.writeCommand(
        'update:ttr:10000:ccd:true:$atSign_2:$key$atSign_1 $value');
    var response = await sh1.read();
    response = response.replaceAll('data:', '');
    expect(response, isNot('null'));

    // Give it a second to propagate to the other atServer
    await Future.delayed(Duration(seconds: 1));

    // verify if cached key is created on the receiver side
    await sh2.writeCommand('llookup:cached:$atSign_2:$key$atSign_1');
    response = await sh2.read();
    response = response.replaceAll('data:', '');
    expect(response, value);

    // Run delete verb
    await sh1.writeCommand('delete:$atSign_2:$key$atSign_1');
    response = await sh1.read();
    response = response.replaceAll('data:', '');
    expect(response, isNot('null'));

    // Give it a second to propagate to the other atServer
    await Future.delayed(Duration(seconds: 1));

    //Check if cached key is deleted
    await sh2.writeCommand('llookup:cached:$atSign_2:$key$atSign_1');
    response = await sh2.read();
    response = response.replaceAll('error:', '');
    var decodedJSON = jsonDecode(response);
    expect(decodedJSON['errorCode'], 'AT0015');
    expect(decodedJSON['errorDescription'], contains('key not found'));
  });
}
