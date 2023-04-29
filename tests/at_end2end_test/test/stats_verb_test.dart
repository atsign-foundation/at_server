import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';

import 'e2e_test_utils.dart' as e2e;
import 'notify_verb_test.dart' as notification;

void main() {
  late String atSign_1;
  late e2e.SimpleOutboundSocketHandler sh1;

  late String atSign_2;
  late e2e.SimpleOutboundSocketHandler sh2;

  var lastValue = Random().nextInt(20);

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

  test(
      'stats verb for id 11 - update operation count from sender for the messageType key',
      () async {
    /// stats:11 verb response
    var beforeUpdate = await notificationStats(sh1);
    var sentCountBeforeUpdate = await beforeUpdate['type']['sent'];
    var statusBeforeUpdate = await beforeUpdate['status']['delivered'];
    var keyCountBeforeUpdate = await beforeUpdate['messageType']['key'];

    /// notify command
    var value = '$lastValue-India';
    await sh1
        .writeCommand('notify:update:ttr:-1:$atSign_2:country$atSign_1:$value');
    var notifyResponse = await sh1.read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterUpdate = await notificationStats(sh1);
    var sentCountAfterUpdate = await afterUpdate['type']['sent'];
    var statusAfterUpdate = await afterUpdate['status']['delivered'];
    var keyCountAfterUpdate = await afterUpdate['messageType']['key'];
    expect(afterUpdate['operations']['update'],
        beforeUpdate['operations']['update'] + 1);
    expect(sentCountAfterUpdate, sentCountBeforeUpdate + 1);
    expect(statusAfterUpdate, statusBeforeUpdate + 1);
    expect(keyCountAfterUpdate, keyCountBeforeUpdate + 1);
  });

  test(
      'stats verb for id 11 - delete operation count from sender for the messageType key',
      () async {
    /// stats:11 verb response
    var beforeDelete = await notificationStats(sh1);
    var sentCountBeforeDelete = await beforeDelete['type']['sent'];
    var statusBeforeDelete = await beforeDelete['status']['delivered'];

    /// delete command
    await sh1.writeCommand('notify:delete:$atSign_2:country$atSign_1');
    var deleteResponse = await sh1.read();
    print(' notify delete verb response $deleteResponse');
    assert((!deleteResponse.contains('Invalid syntax')) &&
        (!deleteResponse.contains('null')));
    String notificationId = deleteResponse.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterDelete = await notificationStats(sh1);
    var sentCountAfterDelete = await afterDelete['type']['sent'];
    var statusAfterDelete = await afterDelete['status']['delivered'];
    expect(afterDelete['operations']['delete'],
        beforeDelete['operations']['delete'] + 1);
    expect(sentCountAfterDelete, sentCountBeforeDelete + 1);
    expect(statusAfterDelete, statusBeforeDelete + 1);
  });

  test('stats verb for id 11 - for messageType text ', () async {
    /// stats:11 verb response
    var beforeNotify = await notificationStats(sh1);
    var sentCountBeforeNotify = await beforeNotify['type']['sent'];
    var statusBeforeNotify = await beforeNotify['status']['delivered'];
    var textCountBeforeNotify = await beforeNotify['messageType']['text'];

    /// update command
    var value = 'Hey $lastValue';
    await sh1.writeCommand(
        'notify:messageType:text:ttr:-1:$atSign_2:message$atSign_1:$value');
    var notifyResponse = await sh1.read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterNotify = await notificationStats(sh1);
    var sentCountAfterNotify = await afterNotify['type']['sent'];
    var statusAfterNotify = await afterNotify['status']['delivered'];
    var textCountAfterNotify = await afterNotify['messageType']['text'];
    expect(sentCountAfterNotify, sentCountBeforeNotify + 1);
    expect(statusAfterNotify, statusBeforeNotify + 1);
    expect(textCountAfterNotify, textCountBeforeNotify + 1);
  });

  test('stats verb for id 11 - for an invalid atsign ', () async {
    /// stats:11 verb response
    var beforeUpdate = await notificationStats(sh1);
    var sentCountBeforeUpdate = await beforeUpdate['type']['sent'];
    var statusBeforeUpdate = await beforeUpdate['status']['failed'];
    var keyCountBeforeUpdate = await beforeUpdate['messageType']['key'];

    /// update command
    var value = '$lastValue-randomNumber';
    await sh1.writeCommand('notify:update:@xxx:no-key$atSign_1:$value');
    var notifyResponse = await sh1.read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['errored'], timeOutMillis: 15000);
    var afterUpdate = await notificationStats(sh1);
    var sentCountAfterUpdate = await afterUpdate['type']['sent'];
    var statusAfterUpdate = await afterUpdate['status']['failed'];
    var keyCountAfterUpdate = await afterUpdate['messageType']['key'];
    expect(afterUpdate['operations']['update'],
        beforeUpdate['operations']['update'] + 1);
    expect(sentCountAfterUpdate, sentCountBeforeUpdate + 1);
    expect(statusAfterUpdate, statusBeforeUpdate + 1);
    expect(keyCountAfterUpdate, keyCountBeforeUpdate + 1);
  });
}

Future<Map> notificationStats(e2e.SimpleOutboundSocketHandler sh) async {
  await sh.writeCommand('stats:11');
  var statsResponse = await sh.read();
  print('stats verb response : $statsResponse');
  var jsonData =
      jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
  return jsonDecode(jsonData[0]['value']);
}
