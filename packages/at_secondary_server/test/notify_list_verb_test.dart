import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/notify_fetch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() async {
  FakeSocket mockSocket = FakeSocket();

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group('A group of notify list verb tests', () {
    test('test notify getVerb', () {
      var handler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var verb = handler.getVerb();
      expect(verb is NotifyList, true);
    });

    test('test notify command accept test', () {
      var command = 'notify:list .me:2021-01-01:2021-01-12';
      var handler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test notify list with params', () {
      var verb = NotifyList();
      var command = 'notify:list:2021-01-01:2021-01-12:.me';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect('.me', paramsMap['regex']);
      expect('2021-01-01', paramsMap['fromDate']);
      expect('2021-01-12', paramsMap['toDate']);
    });

    test('test notify list with regex', () {
      var verb = NotifyList();
      var command = 'notify:list:^phone';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect('^phone', paramsMap['regex']);
    });

    test('test fromDate is populated and toDate is optional', () {
      var verb = NotifyList();
      var command = 'notify:list:2021-01-12:^phone:';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect('^phone', paramsMap['regex']);
      expect('2021-01-12', paramsMap['fromDate']);
    });
  });

  group('A group of notify list negative test', () {
    test('test notify key- invalid keyword', () {
      var verb = NotifyList();
      var command = 'notif:list';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of tests on date time', () {
    test('A test to verify from date', () async {
      var notifyListVerbHandler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var notification1 = (AtNotificationBuilder()
            ..id = '122'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now().subtract(Duration(days: 1))
            ..toAtSign = '@bob'
            ..notification = 'key-2'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();

      var notification2 = (AtNotificationBuilder()
            ..id = '125'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'key-3'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();

      await notifStore.put('122', notification1);
      await notifStore.put('125', notification2);
      var verb = NotifyList();
      // The notify-list handler interprets fromDate as a UTC date —
      // derive the date string from UTC too, otherwise the
      // local-zone date-string can fall outside the UTC window for
      // notifications at the day boundary in non-UTC timezones.
      var date = DateTime.now().toUtc().toString().split(' ')[0];
      var command = 'notify:list:$date';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = alice
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      var result = jsonDecode(response.data!);
      expect('125', result[0]['id']);
      expect('@test_user_1', result[0]['from']);
      expect('@bob', result[0]['to']);
      expect('key-3', result[0]['key']);
      await notifStore.remove('122');
      await notifStore.remove('125');
    });

    test('A test to verify from and to date', () async {
      var notifyListVerbHandler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var notification1 = (AtNotificationBuilder()
            ..id = '121'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now().subtract(Duration(days: 2))
            ..toAtSign = '@bob'
            ..notification = 'key-1'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();

      var notification2 = (AtNotificationBuilder()
            ..id = '122'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now().subtract(Duration(days: 1))
            ..toAtSign = '@bob'
            ..notification = 'key-2'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();

      var notification3 = (AtNotificationBuilder()
            ..id = '123'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 1))
            ..toAtSign = '@bob'
            ..notification = 'key-3'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();

      await notifStore.put('121', notification1);
      await notifStore.put('122', notification2);
      await notifStore.put('123', notification3);
      var verb = NotifyList();
      // The notify-list handler interprets the fromDate/toDate query
      // parameters as UTC dates (window =
      // `[fromDate 00:00:00Z, toDate 23:59:59.999Z]`), so derive the
      // date strings from UTC too. Mixing local-zone date-string
      // derivation here against the UTC-zone handler bounds produced
      // a window that depended on time-of-day in non-UTC timezones.
      var fromDate = DateTime.now()
          .toUtc()
          .subtract(Duration(days: 2))
          .toString()
          .split(' ')[0];
      var toDate = DateTime.now()
          .toUtc()
          .subtract(Duration(days: 1))
          .toString()
          .split(' ')[0];
      var command = 'notify:list:$fromDate:$toDate';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '100';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = alice
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      var result = jsonDecode(response.data!);
      expect('121', result[0]['id']);
      expect('@test_user_1', result[0]['from']);
      expect('@bob', result[0]['to']);
      expect('key-1', result[0]['key']);
      expect('122', result[1]['id']);
      expect('@test_user_1', result[1]['from']);
      expect('@bob', result[1]['to']);
      expect('key-2', result[1]['key']);
      await notifStore.remove('121');
      await notifStore.remove('122');
      await notifStore.remove('123');
    });

    test('validate presence of availableAt in notify:list response', () async {
      DateTime availableAtTestValue = DateTime.now()
          .toUtcMillisecondsPrecision()
          .add(Duration(minutes: 10));
      String testNotificationId = 'notification_available_test';
      String testFromAtsign = '@anon20934820';
      AtMetaData testMetaData = AtMetaData()
        ..availableAt = availableAtTestValue;
      var notification = (AtNotificationBuilder()
            ..id = testNotificationId
            ..fromAtSign = testFromAtsign
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 1))
            ..toAtSign = '@bob'
            ..notification = 'available_at.first_test'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3
            ..atMetaData = testMetaData)
          .build();

      await notifStore.put(testNotificationId, notification);
      NotifyListVerbHandler notifyListVerbHandler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      InboundConnectionMetadata inboundConnectionMetadata =
          InboundConnectionMetadata()
            ..fromAtSign = testFromAtsign.toAtsign()
            ..isAuthenticated = true;
      InboundConnection inboundConnection =
          InboundConnectionImpl(mockSocket, 'sessionId9238472934')
            ..metaData = inboundConnectionMetadata;
      // fetch notify:list response
      Response response = await notifyListVerbHandler.processInternal(
          'notify:list', inboundConnection);
      List<dynamic> jsonDecodedResponse = jsonDecode(response.data!);
      // extract the notification with current notificationId from notify:list response
      var notificationOfInterest = jsonDecodedResponse
          .where((notification) => notification['id'] == testNotificationId)
          .elementAt(0);

      expect(notificationOfInterest['id'], testNotificationId);
      DateTime parsedAvailableAtFromResponse =
          DateTime.parse(notificationOfInterest['metadata']['availableAt']);
      expect(availableAtTestValue.compareTo(parsedAvailableAtFromResponse), 0);

      await notifStore.remove(testNotificationId);
    });
  });

  group('A group of tests on expiry ', () {
    test(
        'A test to verify notify list does not return expired entries - 1 expired entry',
        () async {
      var ttl = 100;
      var notifyListVerbHandler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var notification1 = (AtNotificationBuilder()
            ..id = '122'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'key-2'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3
            ..ttl = ttl)
          .build();

      var notification2 = (AtNotificationBuilder()
            ..id = '125'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'key-3'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();

      await notifStore.put('122', notification1);
      await notifStore.put('125', notification2);

      // We set a ttl on notification1 (id 122) - let's wait until that ttl has passed
      // When we then list the notifications we should only see notification2 (id 125)
      sleep(Duration(milliseconds: ttl + 1));

      var verb = NotifyList();
      var command = 'notify:list';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = alice
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      var result = jsonDecode(response.data!);
      expect(result.length, 1);
      expect(result[0]['id'], '125');
      await notifStore.remove('122');
      await notifStore.remove('125');
    });

    test('A test to verify notify list expired entries - No expired entry',
        () async {
      var notifyListVerbHandler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var notification1 = (AtNotificationBuilder()
            ..id = '122'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'key-2'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3
            ..ttl = 60)
          .build();

      var notification2 = (AtNotificationBuilder()
            ..id = '125'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'key-3'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3
            ..ttl = 70)
          .build();

      await notifStore.put('122', notification1);
      await notifStore.put('125', notification2);

      // We set ttls of 60 and 70 milliseconds respectively on notifications 1 and 2
      // Let's sleep for 20 milliseconds and then verify neither have yet expired
      sleep(Duration(milliseconds: 20));

      var verb = NotifyList();
      var command = 'notify:list';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = alice
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      var result = jsonDecode(response.data!);
      expect(result.length, 2);
      expect(result[0]['id'], '122');
      expect(result[1]['id'], '125');
      await notifStore.remove('122');
      await notifStore.remove('125');
    });

    test('validate presence of expiresAt in notify:list response', () async {
      DateTime expiresAtTestValue = DateTime.now()
          .toUtcMillisecondsPrecision()
          .add(Duration(minutes: 25));
      String testNotificationId = 'notification_id_187';
      String testFromAtsign = '@anon';
      var notification = (AtNotificationBuilder()
            ..id = testNotificationId
            ..fromAtSign = testFromAtsign
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 1))
            ..toAtSign = '@bob'
            ..notification = 'expiry.test'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = expiresAtTestValue
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();

      await notifStore.put(testNotificationId, notification);

      NotifyListVerbHandler notifyListVerbHandler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      InboundConnectionMetadata inboundConnectionMetadata =
          InboundConnectionMetadata()
            ..fromAtSign = testFromAtsign.toAtsign()
            ..isAuthenticated = true;
      InboundConnection inboundConnection =
          InboundConnectionImpl(mockSocket, 'sessionId9238472934')
            ..metaData = inboundConnectionMetadata;
      // fetch notify:list response from server
      Response response = await notifyListVerbHandler.processInternal(
          'notify:list', inboundConnection);
      List<dynamic> jsonDecodedResponse = jsonDecode(response.data!);
      // extract the notification with current notificationId from notify:list response
      var notificationOfInterest = jsonDecodedResponse
          .where((notification) => notification['id'] == testNotificationId)
          .elementAt(0);

      expect(notificationOfInterest['id'], testNotificationId);
      DateTime parsedExpiresAtFromResponse =
          DateTime.parse(notificationOfInterest['metadata']['expiresAt']);
      expect(expiresAtTestValue.compareTo(parsedExpiresAtFromResponse), 0);

      await notifStore.remove(testNotificationId);
    });

    test(
        'validate presence of expiresAt in notify:list response - read expiresAt from metadata',
        () async {
      DateTime expiresAtTestValue = DateTime.now()
          .toUtcMillisecondsPrecision()
          .add(Duration(minutes: 25));
      String testNotificationId = 'notification_id_232';
      String testFromAtsign = '@anon20934820';
      AtMetaData testMetaData = AtMetaData()..expiresAt = expiresAtTestValue;
      var notification = (AtNotificationBuilder()
            ..id = testNotificationId
            ..fromAtSign = testFromAtsign
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 1))
            ..toAtSign = '@bob'
            ..notification = 'expiry.second_test'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3
            ..atMetaData = testMetaData)
          .build();

      await notifStore.put(testNotificationId, notification);

      NotifyListVerbHandler notifyListVerbHandler = NotifyListVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      InboundConnectionMetadata inboundConnectionMetadata =
          InboundConnectionMetadata()
            ..fromAtSign = testFromAtsign.toAtsign()
            ..isAuthenticated = true;
      InboundConnection inboundConnection =
          InboundConnectionImpl(mockSocket, 'sessionId9238472934')
            ..metaData = inboundConnectionMetadata;
      // fetch notify:list response
      Response response = await notifyListVerbHandler.processInternal(
          'notify:list', inboundConnection);
      List<dynamic> jsonDecodedResponse = jsonDecode(response.data!);
      // extract the notification with current notificationId from notify:list response
      var notificationOfInterest = jsonDecodedResponse
          .where((notification) => notification['id'] == testNotificationId)
          .elementAt(0);

      expect(notificationOfInterest['id'], testNotificationId);
      DateTime parsedExpiresAtFromResponse =
          DateTime.parse(notificationOfInterest['metadata']['expiresAt']);
      expect(expiresAtTestValue.compareTo(parsedExpiresAtFromResponse), 0);

      await notifStore.remove(testNotificationId);
    });
  });

  group('A group of test to verify notify fetch', () {
    test('test to fetch notification using notification-id', () async {
      var notifyFetchVerbHandler = NotifyFetchVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var dateTimeNow = DateTime.now();
      var notification1 = (AtNotificationBuilder()
            ..id = '122'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = dateTimeNow
            ..toAtSign = '@bob'
            ..notification = 'key-2'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3
            ..ttl = 100)
          .build();
      await notifStore.put('122', notification1);
      var verbParams = getVerbParam(NotifyFetch().syntax(), 'notify:fetch:122');
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = alice
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyFetchVerbHandler.processVerb(
          response, verbParams, atConnection);
      var atNotification = jsonDecode(response.data!);
      expect(atNotification['id'], '122');
      expect(atNotification['fromAtSign'], '@test_user_1');
      expect(atNotification['toAtSign'], '@bob');
      expect(atNotification['notification'], 'key-2');
      expect(atNotification['type'], NotificationType.received.toString());
      expect(atNotification['notificationStatus'],
          NotificationStatus.queued.toString());
      expect(atNotification['priority'], NotificationPriority.low.toString());
      expect(atNotification['opType'], OperationType.update.toString());
      expect(atNotification['messageType'], MessageType.key.toString());
    });

    test('test to fetch a non existent notification using notification-id',
        () async {
      var notifyFetchVerbHandler = NotifyFetchVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      var verbParams = getVerbParam(NotifyFetch().syntax(), 'notify:fetch:123');
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = alice
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyFetchVerbHandler.processVerb(
          response, verbParams, atConnection);
      var atNotification = jsonDecode(response.data!);
      expect(atNotification['id'], '123');
      expect(atNotification['notificationStatus'],
          NotificationStatus.expired.toString());
    });
  });
}
