import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';


void main() async {
  var lastValue = Random().nextInt(20);
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

// second atsign details
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('stats verb returns result', () async {
    /// STATS VERB
    await socket_writer(socketFirstAtsign!, 'stats');
    var statsResponse = await read();
    print('stats verb response : $statsResponse');
    assert((!statsResponse.contains('Invalid syntax')) &&
        (!statsResponse.contains('data:null')));
  });

  test('stats verb for id 3 ', () async {
    /// STATS VERB
    var value = 'Bob_$lastValue';
    await socket_writer(
        socketFirstAtsign!, 'update:public:username$firstAtsign $value');
    var updateResponse = await read();
    print('update verb response : $updateResponse');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));
    String commitId = updateResponse.trim().replaceAll('data:', '');
    print(commitId);

    /// stats:3 verb response
    await socket_writer(socketFirstAtsign!, 'stats:3');
    var statsResponse = await read();
    print('stats verb response : $statsResponse');
    expect(statsResponse,
        contains('[{"id":"3","name":"lastCommitID","value":"$commitId"'));
  });

  test('stats verb for invalid id ', () async {
    /// STATS VERB
    await socket_writer(socketFirstAtsign!, 'stats:-1');
    var statsResponse = await read();
    print('stats verb esponse : $statsResponse');
    expect(statsResponse, contains('Invalid syntax'));
    // As invalid syntx closes the connection. Creating a new connection
  });

  test(
      'stats verb for id 11 - update operation count from sender for the messageType key',
      () async {
    /// stats:11 verb response
    var beforeUpdate = await notificationStats(socketFirstAtsign!);
    var sentCountBeforeUpdate = await beforeUpdate['type']['sent'];
    var statusBeforeUpdate = await beforeUpdate['status']['delivered'];
    var keyCountBeforeUpdate = await beforeUpdate['messageType']['key'];

    /// notify command
    var value = '$lastValue-India';
    await socket_writer( socketFirstAtsign!, 'notify:update:ttr:-1:$secondAtsign:country$firstAtsign:$value');
    var notifyResponse = await read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await getNotifyStatus(socketFirstAtsign!, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterUpdate = await notificationStats(socketFirstAtsign!);
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
      'stats verb for id 11 - update operation count from receiver for the messageType key',
      () async {
    /// stats:11 verb response
    var beforeUpdateCount = await notificationStats(socketFirstAtsign!);
    var receivedCountBeforeUpdate = beforeUpdateCount['type']['received'];

    /// update command
    var value = '$lastValue-UK';
    await socket_writer(socketFirstAtsign!, 'notify:update:$firstAtsign:country$firstAtsign:$value');
    var notifyResponse = await read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await getNotifyStatus(socketFirstAtsign!, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterUpdateCount = await notificationStats(socketFirstAtsign!);
    var receivedCountAfterUpdate = afterUpdateCount['type']['received'];
    expect(afterUpdateCount['operations']['update'],
        beforeUpdateCount['operations']['update'] + 1);
    expect(receivedCountAfterUpdate, receivedCountBeforeUpdate + 1);
  }, timeout: Timeout(Duration(seconds: 120)));

  test(
      'stats verb for id 11 - delete operation count from sender for the messageType key',
      () async {
    /// stats:11 verb response
    var beforeDelete = await notificationStats(socketFirstAtsign!);
    var sentCountBeforeDelete = await beforeDelete['type']['sent'];
    var statusBeforeDelete = await beforeDelete['status']['delivered'];

    /// delete command
    await socket_writer(
        socketFirstAtsign!, 'notify:delete:$secondAtsign:country$firstAtsign');
    var deleteResponse = await read();
    print(' notify delete verb response $deleteResponse');
    assert((!deleteResponse.contains('Invalid syntax')) &&
        (!deleteResponse.contains('null')));
    String notificationId = deleteResponse.replaceAll('data:', '');
    await getNotifyStatus(socketFirstAtsign!, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterDelete = await notificationStats(socketFirstAtsign!);
    var sentCountAfterDelete = await afterDelete['type']['sent'];
    var statusAfterDelete = await afterDelete['status']['delivered'];
    expect(afterDelete['operations']['delete'],
        beforeDelete['operations']['delete'] + 1);
    expect(sentCountAfterDelete, sentCountBeforeDelete + 1);
    expect(statusAfterDelete, statusBeforeDelete + 1);
  });

  test('stats verb for id 11 - delete operation count from receiver', () async {
    /// stats:11 verb response
    var beforeDelete = await notificationStats(socketFirstAtsign!);
    var sentCountBeforeDelete = await beforeDelete['type']['received'];

    /// delete command
    await socket_writer(socketFirstAtsign!, 'notify:delete:$firstAtsign:country$firstAtsign');
    var deleteResponse = await read();
    print('notify delete verb response $deleteResponse');
    assert((!deleteResponse.contains('Invalid syntax')) &&
        (!deleteResponse.contains('null')));
    String notificationId = deleteResponse.replaceAll('data:', '');
    await getNotifyStatus(socketFirstAtsign!, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterDelete = await notificationStats(socketFirstAtsign!);
    var sentCountAfterDelete = await afterDelete['type']['received'];
    expect(afterDelete['operations']['delete'],
        beforeDelete['operations']['delete'] + 1);
    expect(sentCountAfterDelete, sentCountBeforeDelete + 1);
  }, timeout: Timeout(Duration(seconds: 120)));

  test('stats verb for id 11 - for messageType text ', () async {
    /// stats:11 verb response
    var beforeNotify = await notificationStats(socketFirstAtsign!);
    var sentCountBeforeNotify = await beforeNotify['type']['sent'];
    var statusBeforeNotify = await beforeNotify['status']['delivered'];
    var textCountBeforeNotify = await beforeNotify['messageType']['text'];

    /// update command
    var value = 'Hey $lastValue';
    await socket_writer(socketFirstAtsign!,
        'notify:messageType:text:ttr:-1:$secondAtsign:message$firstAtsign:$value');
    var notifyResponse = await read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await getNotifyStatus(socketFirstAtsign!, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterNotify = await notificationStats(socketFirstAtsign!);
    var sentCountAfterNotify = await afterNotify['type']['sent'];
    var statusAfterNotify = await afterNotify['status']['delivered'];
    var textCountAfterNotify = await afterNotify['messageType']['text'];
    expect(sentCountAfterNotify, sentCountBeforeNotify + 1);
    expect(statusAfterNotify, statusBeforeNotify + 1);
    expect(textCountAfterNotify, textCountBeforeNotify + 1);
  });

  test('stats verb for id 11 - for an invalid atsign ', () async {
    /// stats:11 verb response
    var beforeUpdate = await notificationStats(socketFirstAtsign!);
    var sentCountBeforeUpdate = await beforeUpdate['type']['sent'];
    var statusBeforeUpdate = await beforeUpdate['status']['failed'];
    var keyCountBeforeUpdate = await beforeUpdate['messageType']['key'];

    /// update command
    var value = '$lastValue-randomNumber';
    await socket_writer(
        socketFirstAtsign!, 'notify:update:@xxx:no-key$firstAtsign:$value');
    var notifyResponse = await read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await getNotifyStatus(socketFirstAtsign!, notificationId,
        returnWhenStatusIn: ['errored'], timeOutMillis: 15000);
    var afterUpdate = await notificationStats(socketFirstAtsign!);
    var sentCountAfterUpdate = await afterUpdate['type']['sent'];
    var statusAfterUpdate = await afterUpdate['status']['failed'];
    var keyCountAfterUpdate = await afterUpdate['messageType']['key'];
    expect(afterUpdate['operations']['update'],
        beforeUpdate['operations']['update'] + 1);
    expect(sentCountAfterUpdate, sentCountBeforeUpdate + 1);
    expect(statusAfterUpdate, statusBeforeUpdate + 1);
    expect(keyCountAfterUpdate, keyCountBeforeUpdate + 1);
  });

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}

Future<Map> notificationStats(Socket socket) async {
  await socket_writer(socket, 'stats:11');
  var statsResponse = await read();
  print('stats verb response : $statsResponse');
  var jsonData =
      jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
  return jsonDecode(jsonData[0]['value']);
}

Future<String> getNotifyStatus(Socket socket, String notificationId,
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
      await socket_writer(socket, 'notify:status:$notificationId');
    }
    response = await read();

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
