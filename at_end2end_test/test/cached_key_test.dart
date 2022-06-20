import 'dart:math';

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
  /// 4. lookup with bypass_cache set to true should return the updated value
  /// 5. lookup with bypass_cache set to false should return the old value
  test('update-lookup verb passing bypasscache ', () async {
    ///Update verb on atsign_1
    var oldValue = 'Hyderabad';

    await sh1
        .writeCommand('update:ttr:100000:$atSign_2:fav-city$atSign_1  $oldValue');
    String response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

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
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup should return the old value
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

    /// lookup with bypass_cache set to false
    /// should return the old value
    await sh2.writeCommand('lookup:bypassCache:false:fav-city$atSign_1');
    response = await sh2.read();
    print('lookup verb response : $response');
    expect(response, contains('data: $oldValue'));

    // reset the autoNotify to default
    await sh1.writeCommand('config:reset:autoNotify');
    response = await sh1.read();
    print('config set verb response is $response');
    expect(response, contains('data:ok'));
  }, timeout: Timeout(Duration(minutes: 3)));

  // Will uncomment after validations are in place
  // test('update-llookup verb without ttr and with ccd', () async {
  //   /// UPDATE VERB
  //   await sh1.writeCommand('update:ccd:true:$atSign_2:sample$atSign_1 sams');
  //   var response = await sh1.read();
  //   print('update verb response : $response');
  //   assert((response.contains('Invalid syntax')));
  // });
}
