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
      'stats verb for id 11 - update operation count from receiver for the messageType key',
      () async {
    /// stats:11 verb response
    var beforeUpdateCount = await notificationStats(socketFirstAtsign!);
    var receivedCountBeforeUpdate = beforeUpdateCount['type']['received'];

    /// update command
    var value = '$lastValue-UK';
    await socket_writer(socketFirstAtsign!,
        'notify:update:$firstAtsign:country$firstAtsign:$value');
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

  test('stats verb for id 11 - delete operation count from receiver', () async {
    /// stats:11 verb response
    var beforeDelete = await notificationStats(socketFirstAtsign!);
    var sentCountBeforeDelete = await beforeDelete['type']['received'];

    /// delete command
    await socket_writer(
        socketFirstAtsign!, 'notify:delete:$firstAtsign:country$firstAtsign');
    var deleteResponse = await read();
    print('notify delete verb response $deleteResponse');
    assert((!deleteResponse.contains('Invalid syntax')) &&
        (!deleteResponse.contains('null')));
    String notificationId = deleteResponse.replaceAll('data:', '');
    await getNotifyStatus(socketFirstAtsign!, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 20000);
    // wait for seconds for the type to be updated
    await Future.delayed(Duration(seconds: 5));
    var afterDelete = await notificationStats(socketFirstAtsign!);
    var sentCountAfterDelete = await afterDelete['type']['received'];
    expect(afterDelete['operations']['delete'],
        beforeDelete['operations']['delete'] + 1);
    expect(sentCountAfterDelete, sentCountBeforeDelete + 1);
  }, timeout: Timeout(Duration(seconds: 120)));

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
