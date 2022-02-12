@Skip('Many of these tests are currently flaky due to timing? issues')

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_end2end_test/conf/config_util.dart';

void main() {
  var commitId;
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign, socketSecondAtsign;

// second atsign details
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  setUp(() async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    var secondAtsignServer = ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_url'];
    var secondAtsignPort =
        ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);

    //Socket connection for second atsign
    socketSecondAtsign = await secure_socket_connection(
        secondAtsignServer, secondAtsignPort);
    socket_listener(socketSecondAtsign!);
    await prepare(socketSecondAtsign!, secondAtsign);
  });

  test('stats verb returns result', () async {
    /// STATS VERB
    await socket_writer(socketFirstAtsign!, 'stats');
    var response = await read();
    print('stats verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
  });

  test('stats verb for id 3 ', () async {
    /// STATS VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:username$firstAtsign Bob!');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    commitId = response.trim().replaceAll('data:', '');
    print(commitId);

    /// stats:3 verb response
    await socket_writer(socketFirstAtsign!, 'stats:3');
    response = await read();
    print('stats verb response : $response');
    expect(response,
        contains('[{"id":"3","name":"lastCommitID","value":"$commitId"'));
  });

  test('stats verb for invalid id ', () async {
    /// STATS VERB
    await socket_writer(socketFirstAtsign!, 'stats:-1');
    var response = await read();
    print('update verb response : $response');
    expect(response, contains('-Invalid syntax'));
  });

  test(
      'stats verb for id 11 - update operation count from sender for the messageType key',
      () async {
    /// stats:11 verb response
    var beforeUpdate = await notificationStats(socketFirstAtsign!);
    var sentCountBeforeUpdate = await beforeUpdate['type']['sent'];
    var statusBeforeUpdate = await beforeUpdate['status']['delivered'];
    var keyCountBeforeUpdate = await beforeUpdate['messageType']['key'];

    /// update command
    await socket_writer(socketFirstAtsign!,
        'update:$secondAtsign:country$firstAtsign India');
    var updateResponse = await read();
    print('update verb response $updateResponse');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));
    await Future.delayed(Duration(seconds: 16));
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
    var beforeUpdateCount = await notificationStats(socketSecondAtsign!);
    var receivedCountBeforeUpdate = beforeUpdateCount['type']['received'];

    /// update command
    await socket_writer(socketFirstAtsign!,
        'update:$secondAtsign:country$firstAtsign India');
    var updateResponse = await read();
    print('update verb response $updateResponse');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));
    await Future.delayed(Duration(seconds: 16));
    var afterUpdateCount = await notificationStats(socketSecondAtsign!);
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
        socketFirstAtsign!, 'delete:$secondAtsign:country$firstAtsign');
    var deleteResponse = await read();
    print('delete verb response $deleteResponse');
    assert((!deleteResponse.contains('Invalid syntax')) &&
        (!deleteResponse.contains('null')));
    await Future.delayed(Duration(seconds: 16));
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
    var beforeDelete = await notificationStats(socketSecondAtsign!);
    var sentCountBeforeDelete = await beforeDelete['type']['received'];

    /// delete command
    await socket_writer(
        socketFirstAtsign!, 'delete:$secondAtsign:country$firstAtsign');
    var deleteResponse = await read();
    print('delete verb response $deleteResponse');
    assert((!deleteResponse.contains('Invalid syntax')) &&
        (!deleteResponse.contains('null')));
    await Future.delayed(Duration(seconds: 16));
    var afterDelete = await notificationStats(socketSecondAtsign!);
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
    await socket_writer(socketFirstAtsign!,
        'notify:messageType:text:ttr:-1:$secondAtsign:message$firstAtsign:Hi!!!');
    var notifyResponse = await read();
    print('notify verb response $notifyResponse');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    await Future.delayed(Duration(seconds: 16));
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
    await socket_writer(
        socketFirstAtsign!, 'update:@xxx:country$firstAtsign India');
    var updateResponse = await read();
    print('update verb response $updateResponse');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));
    await Future.delayed(Duration(seconds: 16));
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
