import 'dart:convert';
import 'dart:math';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

void main() async {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();

  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  var lastValue = Random().nextInt(20);

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
  });

  test('stats verb returns result', () async {
    /// STATS VERB
    String statsResponse =
        await firstAtSignConnection.sendRequestToServer('stats');
    assert((!statsResponse.contains('Invalid syntax')) &&
        (!statsResponse.contains('data:null')));
  });

  test('stats verb for id 3 ', () async {
    /// STATS VERB
    var value = 'Bob_$lastValue';
    String updateResponse = await firstAtSignConnection
        .sendRequestToServer('update:public:username$firstAtSign $value');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));
    String commitId = updateResponse.trim().replaceAll('data:', '');

    /// stats:3 verb response
    String statsResponse =
        await firstAtSignConnection.sendRequestToServer('stats:3');
    expect(statsResponse,
        contains('[{"id":"3","name":"lastCommitID","value":"$commitId"'));
  });

  test('stats verb for invalid id ', () async {
    /// STATS VERB
    String statsResponse =
        await firstAtSignConnection.sendRequestToServer('stats:-1');
    expect(statsResponse, contains('Invalid syntax'));
  });

  test(
      'stats verb for id 11 - update operation count from receiver for the messageType key',
      () async {
    var beforeUpdateCount = await notificationStats(firstAtSignConnection);
    int receivedCountBeforeUpdate = beforeUpdateCount['type']['received'];
    // update command
    String value = '$lastValue-UK';
    String notifyResponse = await firstAtSignConnection.sendRequestToServer(
        'notify:update:$firstAtSign:country$firstAtSign:$value');
    assert((!notifyResponse.contains('Invalid syntax')) &&
        (!notifyResponse.contains('null')));
    String notificationId = notifyResponse.replaceAll('data:', '');
    await getNotifyStatus(firstAtSignConnection, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    var afterUpdateCount = await notificationStats(firstAtSignConnection);
    var receivedCountAfterUpdate = afterUpdateCount['type']['received'];
    expect(afterUpdateCount['operations']['update'],
        beforeUpdateCount['operations']['update'] + 1);
    expect(receivedCountAfterUpdate, receivedCountBeforeUpdate + 1);
  });

  test('stats verb for id 11 - delete operation count from receiver', () async {
    /// stats:11 verb response
    var beforeDelete = await notificationStats(firstAtSignConnection);
    int sentCountBeforeDelete = await beforeDelete['type']['received'];

    /// delete command
    String deleteResponse = await firstAtSignConnection
        .sendRequestToServer('notify:delete:$firstAtSign:country$firstAtSign');
    assert((!deleteResponse.contains('Invalid syntax')) &&
        (!deleteResponse.contains('null')));
    String notificationId = deleteResponse.replaceAll('data:', '');
    await getNotifyStatus(firstAtSignConnection, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 20000);
    // wait for seconds for the type to be updated
    await Future.delayed(Duration(seconds: 5));
    var afterDelete = await notificationStats(firstAtSignConnection);
    var sentCountAfterDelete = await afterDelete['type']['received'];
    expect(afterDelete['operations']['delete'],
        beforeDelete['operations']['delete'] + 1);
    expect(sentCountAfterDelete, sentCountBeforeDelete + 1);
  });

  tearDownAll(() {
    firstAtSignConnection.close();
  });
}

Future<Map> notificationStats(
    OutboundConnectionFactory outboundConnectionFactory) async {
  String statsResponse =
      await outboundConnectionFactory.sendRequestToServer('stats:11');
  var jsonData =
      jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
  return jsonDecode(jsonData[0]['value']);
}

Future<String> getNotifyStatus(
    OutboundConnectionFactory outboundConnectionFactory, String notificationId,
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
      response = await outboundConnectionFactory
          .sendRequestToServer('notify:status:$notificationId');
    }

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
