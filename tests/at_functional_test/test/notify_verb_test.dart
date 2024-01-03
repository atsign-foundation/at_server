import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late String uniqueId;
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();

  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
  });

  setUp(() {
    uniqueId = Uuid().v4();
  });

  group('A group of negative tests of notify verb', () {
    test('notify verb without giving message type value', () async {
      /// NOTIFY VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:update:messageType:notifier:system:ttr:-1:$firstAtSign:email-$uniqueId$firstAtSign');
      assert((response.contains('Invalid syntax')));
    });

    test('notify verb without giving notifier for strategy latest', () async {
      // NOTIFY VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:update:messageType:key:strategy:latest:ttr:-1:$firstAtSign:email-$uniqueId$firstAtSign');
      assert((response.contains('Invalid syntax')));
    });

    test('notify verb in an incorrect order', () async {
      // NOTIFY VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:messageType:key:update:notifier:system:ttr:-1:$firstAtSign:email-$uniqueId$firstAtSign');
      assert((response.contains('Invalid syntax')));
    });

    test('notify verb with notification expiry in an incorrect spelling',
        () async {
      // NOTIFY VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:update:ttlnn:5000:ttr:-1:$firstAtSign:message-$uniqueId$firstAtSign:Hey!');
      expect(response, contains('Invalid syntax'));
    });

    test('notify verb with notification expiry without value for ttln',
        () async {
      // NOTIFY VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:update:ttln:ttr:-1:$firstAtSign:message-$uniqueId$firstAtSign:Hey!');
      expect(response, contains('Invalid syntax'));
    });

    test('notify verb with notification expiry in an incorrect order',
        () async {
      // NOTIFY VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:update:ttb:3000:ttr:-1:ttln:10000:$firstAtSign:message-$uniqueId$firstAtSign:Hey!');
      expect(response, contains('Invalid syntax'));
    });
  });

  group('A group of tests to verify notify fetch', () {
    test('A test to verify notification shared to current atSign is fetched',
        () async {
      // Store notification
      var notificationId = await firstAtSignConnection
          .sendRequestToServer('notify:$firstAtSign:phone-$uniqueId.me$firstAtSign');
      notificationId = notificationId.replaceFirst('data:', '');
      // Fetch notification using notification id
      String response = await firstAtSignConnection
          .sendRequestToServer('notify:fetch:$notificationId');

      response = response.replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId.trim());
      expect(atNotificationMap['fromAtSign'], firstAtSign);
      expect(atNotificationMap['toAtSign'], firstAtSign);
      expect(atNotificationMap['type'], 'NotificationType.received');
      expect(atNotificationMap['messageType'], "MessageType.key");
      expect(atNotificationMap['priority'], "NotificationPriority.low");
      expect(atNotificationMap['retryCount'], "1");
      expect(atNotificationMap['strategy'], "all");
    });

    test('A test to verify fetching notification that is deleted', () async {
      var notificationId = '124-abc';
      // Fetch notification using notification id that does not exist
      var response = await firstAtSignConnection
          .sendRequestToServer('notify:fetch:$notificationId');
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
      // NOTIFY VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:update:$firstAtSign:nottrkey-$uniqueId$firstAtSign');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      String notificationId = response.replaceAll('data:', '');
      // notify status
      response = await firstAtSignConnection
          .sendRequestToServer('notify:status:$notificationId');
      assert(response.contains('data:delivered'));

      ///notify:list verb
      response = await firstAtSignConnection
          .sendRequestToServer('notify:list:nottrkey');
      expect(
          response,
          contains(
              '"key":"$firstAtSign:nottrkey-$uniqueId$firstAtSign","value":null,"operation":"update"'));
    });

    test(
        'notify verb without ttr and with value for operation type update (self notification)',
        () async {
      // NOTIFY VERB
      var value = 'no-ttr';
      String response = await firstAtSignConnection.sendRequestToServer(
          'notify:update:$firstAtSign:nottrkey-$uniqueId$firstAtSign:$value');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      String notificationId = response.replaceAll('data:', '');
      // notify status
      response = await firstAtSignConnection
          .sendRequestToServer('notify:status:$notificationId');
      assert(response.contains('data:delivered'));
      //notify:list verb
      response = await firstAtSignConnection.sendRequestToServer('notify:list');
      expect(
          response,
          contains(
              '"key":"$firstAtSign:nottrkey-$uniqueId$firstAtSign","value":"$value","operation":"update"'));
    });
  });

  group('A group of tests to verify notification date time', () {
    test('A test to verify two notification to self has correct date time',
        () async {
      // Sending first notification
      String response = await firstAtSignConnection
          .sendRequestToServer('notify:$firstAtSign:phone-$uniqueId.me$firstAtSign');
      await (Future.delayed(Duration(milliseconds: 5)));
      var dateTimeAfterFirstNotification = DateTime.now();
      await (Future.delayed(Duration(milliseconds: 5)));
      // Sending second notification
      String notificationId = await firstAtSignConnection
          .sendRequestToServer('notify:$firstAtSign:about-$uniqueId.me$firstAtSign');
      notificationId = notificationId.replaceFirst('data:', '');
      response = await firstAtSignConnection
          .sendRequestToServer('notify:fetch:$notificationId');
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

  tearDownAll(() async {
    await firstAtSignConnection.close();
  });
}
