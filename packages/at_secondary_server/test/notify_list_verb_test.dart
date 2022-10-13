import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/notify_fetch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() {
  var storageDir = Directory.current.path + '/test/hive';
  late SecondaryKeyStoreManager keyStoreManager;
  group('A group of notify list verb tests', () {
    test('test notify getVerb', () {
      var handler = NotifyListVerbHandler(null);
      var verb = handler.getVerb();
      expect(verb is NotifyList, true);
    });

    test('test notify command accept test', () {
      var command = 'notify:list .me:2021-01-01:2021-01-12';
      var handler = NotifyListVerbHandler(null);
      var result = handler.accept(command);
      print('result : $result');
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
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));
    test('A test to verify from date', () async {
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStoreManager.getKeyStore());
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

      await AtNotificationKeystore.getInstance().put('122', notification1);
      await AtNotificationKeystore.getInstance().put('125', notification2);
      var verb = NotifyList();
      var date = DateTime.now().toString().split(' ')[0];
      var command = 'notify:list:$date';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = '@alice'
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(null, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      var result = jsonDecode(response.data!);
      expect('125', result[0]['id']);
      expect('@test_user_1', result[0]['from']);
      expect('@bob', result[0]['to']);
      expect('key-3', result[0]['key']);
      await AtNotificationKeystore.getInstance().remove('122');
      await AtNotificationKeystore.getInstance().remove('125');
    });

    test('A test to verify from and to date', () async {
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStoreManager.getKeyStore());
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

      await AtNotificationKeystore.getInstance().put('121', notification1);
      await AtNotificationKeystore.getInstance().put('122', notification2);
      await AtNotificationKeystore.getInstance().put('123', notification3);
      var verb = NotifyList();
      var fromDate =
          DateTime.now().subtract(Duration(days: 2)).toString().split(' ')[0];
      var toDate =
          DateTime.now().subtract(Duration(days: 1)).toString().split(' ')[0];
      var command = 'notify:list:$fromDate:$toDate';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '100';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = '@alice'
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(null, inBoundSessionId)
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
      await AtNotificationKeystore.getInstance().remove('121');
      await AtNotificationKeystore.getInstance().remove('122');
      await AtNotificationKeystore.getInstance().remove('123');
    });
    tearDown(() async => await tearDownFunc());
  });
  group('A group of tests on expiry ', () {
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));
    test(
        'A test to verify notify list does not return expired entries - 1 expired entry',
        () async {
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStoreManager.getKeyStore());
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
            ..ttl = 100)
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

      await AtNotificationKeystore.getInstance().put('122', notification1);
      await AtNotificationKeystore.getInstance().put('125', notification2);
      sleep(Duration(milliseconds: 500));
      var verb = NotifyList();
      var command = 'notify:list';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = '@alice'
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(null, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      var result = jsonDecode(response.data!);
      print(result);
      expect(result.length, 1);
      expect(result[0]['id'], '125');
      await AtNotificationKeystore.getInstance().remove('122');
      await AtNotificationKeystore.getInstance().remove('125');
    });

    test('A test to verify notify list expired entries - No expired entry',
        () async {
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStoreManager.getKeyStore());
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
            ..ttl = 60000)
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
            ..ttl = 70000)
          .build();

      await AtNotificationKeystore.getInstance().put('122', notification1);
      await AtNotificationKeystore.getInstance().put('125', notification2);
      sleep(Duration(milliseconds: 500));
      var verb = NotifyList();
      var command = 'notify:list';
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = '@alice'
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(null, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      var result = jsonDecode(response.data!);
      print(result);
      expect(result.length, 2);
      expect(result[0]['id'], '122');
      expect(result[1]['id'], '125');
      await AtNotificationKeystore.getInstance().remove('122');
      await AtNotificationKeystore.getInstance().remove('125');
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of test to verify notify fetch', () {
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));
    test('test to fetch notification using notification-id', () async {
      var notifyFetchVerbHandler =
          NotifyFetchVerbHandler(keyStoreManager.getKeyStore());
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
      await AtNotificationKeystore.getInstance().put('122', notification1);
      var verbParams = getVerbParam(NotifyFetch().syntax(), 'notify:fetch:122');
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = '@alice'
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(null, inBoundSessionId)
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
      var notifyFetchVerbHandler =
          NotifyFetchVerbHandler(keyStoreManager.getKeyStore());
      var verbParams = getVerbParam(NotifyFetch().syntax(), 'notify:fetch:123');
      var inBoundSessionId = '123';
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = '@alice'
        ..isAuthenticated = true;
      var atConnection = InboundConnectionImpl(null, inBoundSessionId)
        ..metaData = metadata;
      var response = Response();
      await notifyFetchVerbHandler.processVerb(
          response, verbParams, atConnection);
      var atNotification = jsonDecode(response.data!);
      print(atNotification);
      expect(atNotification['id'], '123');
      expect(atNotification['notificationStatus'],
          NotificationStatus.expired.toString());
    });
    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir, {String? atsign}) async {
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atsign ?? '@test_user_1')!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  hiveKeyStore.commitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(atsign ?? '@test_user_1', commitLogPath: storageDir);
  await AtAccessLogManagerImpl.getInstance()
      .getAccessLog(atsign ?? '@test_user_1', accessLogPath: storageDir);
  var notificationInstance = AtNotificationKeystore.getInstance();
  notificationInstance.currentAtSign = atsign ?? '@test_user_1';
  await notificationInstance.init(storageDir);
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  AtNotificationMap.getInstance().clear();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
