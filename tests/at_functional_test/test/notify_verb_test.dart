import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  Socket? socketFirstAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    firstAtsignServer = firstAtsignServer.toString().trim();
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  group('A group of negative tests of notify verb', () {
    test('notify verb without giving message type value', () async {
      /// NOTIFY VERB
      await socket_writer(socketFirstAtsign!,
          'notify:update:messageType:notifier:system:ttr:-1:$firstAtsign:email$firstAtsign');
      String response = await read();
      print('notify verb response : $response');
      assert((response.contains('Invalid syntax')));
      // // Invalid syntax results in a closed connection so let's do some housekeeping
      // sh1.close();
      // sh1 = await e2e.getSocketHandler(atSign_1);
    });

    test('notify verb without giving notifier for strategy latest', () async {
      //   /// NOTIFY VERB
      await socket_writer(socketFirstAtsign!,
          'notify:update:messageType:key:strategy:latest:ttr:-1:$firstAtsign:email$firstAtsign');
      String response = await read();
      print('notify verb response : $response');
      assert((response.contains('Invalid syntax')));
      // Invalid syntax results in a closed connection so let's do some housekeeping
      // sh1.close();
      // sh1 = await e2e.getSocketHandler(atSign_1);
    });

    test('notify verb in an incorrect order', () async {
      /// NOTIFY VERB
      await socket_writer(socketFirstAtsign!,
          'notify:messageType:key:update:notifier:system:ttr:-1:$firstAtsign:email$firstAtsign');
      String response = await read();
      print('notify verb response : $response');
      assert((response.contains('Invalid syntax')));
      // // Invalid syntax results in a closed connection so let's do some housekeeping
      // sh1.close();
      // sh1 = await e2e.getSocketHandler(atSign_1);
    });

    test('notify verb with notification expiry in an incorrect spelling',
        () async {
      //   /// NOTIFY VERB
      await socket_writer(socketFirstAtsign!,
          'notify:update:ttlnn:5000:ttr:-1:$firstAtsign:message$firstAtsign:Hey!');
      String response = await read();
      print('notify verb response : $response');
      expect(response, contains('Invalid syntax'));
      // Invalid syntax results in a closed connection so let's do some housekeeping
      // sh2.close();
      // sh2 = await e2e.getSocketHandler(atSign_2);
    });

    test('notify verb with notification expiry without value for ttln',
        () async {
      //   /// NOTIFY VERB
      await socket_writer(socketFirstAtsign!,
          'notify:update:ttln:ttr:-1:$firstAtsign:message$firstAtsign:Hey!');
      String response = await read();
      print('notify verb response : $response');
      expect(response, contains('Invalid syntax'));
    });

    test('notify verb with notification expiry in an incorrect order',
        () async {
      //   /// NOTIFY VERB
      await socket_writer(socketFirstAtsign!,
          'notify:update:ttb:3000:ttr:-1:ttln:10000:$firstAtsign:message$firstAtsign:Hey!');
      String response = await read();
      print('notify verb response : $response');
      expect(response, contains('Invalid syntax'));
    });
  });

  group('A group of tests to verify notify fetch', () {
    test('A test to verify notification shared to current atSign is fetched',
        () async {
      // Store notification
      await socket_writer(
          socketFirstAtsign!, 'notify:$firstAtsign:phone.me$firstAtsign');
      var notificationId = await read();
      notificationId = notificationId.replaceFirst('data:', '');
      // Fetch notification using notification id
      await socket_writer(socketFirstAtsign!, 'notify:fetch:$notificationId');
      var response = await read();
      response = response.replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId.trim());
      expect(atNotificationMap['fromAtSign'], firstAtsign);
      expect(atNotificationMap['toAtSign'], firstAtsign);
      expect(atNotificationMap['type'], 'NotificationType.received');
      expect(atNotificationMap['messageType'], "MessageType.key");
      expect(atNotificationMap['priority'], "NotificationPriority.low");
      expect(atNotificationMap['retryCount'], "1");
      expect(atNotificationMap['strategy'], "all");
    });

    test('A test to verify fetching notification that is deleted', () async {
      var notificationId = '124-abc';
      // Fetch notification using notification id that does not exist
      await socket_writer(socketFirstAtsign!, 'notify:fetch:$notificationId');
      var response = await read();
      response = response.replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId.trim());
      expect(atNotificationMap['notificationStatus'],
          'NotificationStatus.expired');
    });
  });

  group('A group of tests related to notify ephemeral', () {
    test(
        'notify verb without ttr and without value for operation type update (self notification)',
        () async {
      /// NOTIFY VERB
      await socket_writer(socketFirstAtsign!,
          'notify:update:$firstAtsign:nottrkey$firstAtsign');
      String response = await read();
      print('notify verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      String notificationId = response.replaceAll('data:', '');

      // notify status
      await socket_writer(socketFirstAtsign!, 'notify:status:$notificationId');
      response = await read(maxWaitMilliSeconds: 15000);
      print('notify status response : $response');
      assert(response.contains('data:delivered'));

      ///notify:list verb
      await socket_writer(socketFirstAtsign!, 'notify:list:nottrkey');
      response = await read(maxWaitMilliSeconds: 15000);
      print('notify list verb response : $response');
      expect(
          response,
          contains(
              '"key":"$firstAtsign:nottrkey$firstAtsign","value":null,"operation":"update"'));
    });

    test(
        'notify verb without ttr and with value for operation type update (self notification)',
        () async {
      /// NOTIFY VERB
      var value = 'no-ttr';
      await socket_writer(socketFirstAtsign!,
          'notify:update:$firstAtsign:nottrkey$firstAtsign:$value');
      String response = await read();
      print('notify verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      String notificationId = response.replaceAll('data:', '');

      // notify status
      await socket_writer(socketFirstAtsign!, 'notify:status:$notificationId');
      response = await read();
      print('notify status response : $response');
      assert(response.contains('data:delivered'));

      ///notify:list verb
      await socket_writer(socketFirstAtsign!, 'notify:list');
      response = await read();
      print('notify list verb response : $response');
      expect(
          response,
          contains(
              '"key":"$firstAtsign:nottrkey$firstAtsign","value":"$value","operation":"update"'));
    });
  });

  group('A group of tests to verify notification date time', () {
    test('A test to verify two notification to self has correct date time',
        () async {
      // Sending first notification
      await socket_writer(
          socketFirstAtsign!, 'notify:$firstAtsign:phone.me$firstAtsign');
      var response = await read();

      await (Future.delayed(Duration(milliseconds: 5)));

      var dateTimeAfterFirstNotification = DateTime.now();

      await (Future.delayed(Duration(milliseconds: 5)));

      // Sending second notification
      await socket_writer(
          socketFirstAtsign!, 'notify:$firstAtsign:about.me$firstAtsign');
      var notificationId = await read();
      notificationId = notificationId.replaceFirst('data:', '');
      await socket_writer(socketFirstAtsign!, 'notify:fetch:$notificationId');
      response = await read();
      response = response.replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId.trim());
      // the date time of the second notification should be greater than the current Date Time
      expect(
          DateTime.parse(atNotificationMap['notificationDateTime'])
                  .microsecondsSinceEpoch >
              dateTimeAfterFirstNotification.microsecondsSinceEpoch,
          true);
    });
  });
}
