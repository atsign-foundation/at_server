import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_commons/src/at_constants.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  // String thisTestFileName = 'notify_verb_test.dart';

  var testDataStoragePathRoot = Directory.current.path + '/test/hive/notify_verb_test';

  List<String> testNames = <String>[];

  Future<SecondaryKeyStoreManager> doSetUpForSpecificTest(String specificTestName) async {
    // TODO This is a temporary situation. Problem here is not being able to run tests concurrently because of the way the notifications work.
    // TODO For now we're going to create a specific Hive setup for each individual test.
    // TODO That didn't work either because AtNotificationMap is a singleton also.
    // TODO So now forcing serialization of just these tests by doing a horribly hokey thing
    testNames.add(specificTestName);
    while (testNames.indexOf(specificTestName) != 0) {
      sleep(Duration(milliseconds: 10));
    }

    // print(thisTestFileName + ' notify_verb_test doSetUpForSpecificTest starting for ' + specificTestName);

    String atSignForTests = '@test_user_1';

    String storagePathThisTest = testDataStoragePathRoot + '/' + specificTestName;

    AtSecondaryServerImpl.getInstance().currentAtSign = atSignForTests;

    var secondaryPersistenceStore =
    SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(AtSecondaryServerImpl.getInstance().currentAtSign)!;

    await secondaryPersistenceStore.getHivePersistenceManager()!.init(storagePathThisTest);

    var commitLogInstance = await AtCommitLogManagerImpl.getInstance().getCommitLog(atSignForTests, commitLogPath: storagePathThisTest);
    secondaryPersistenceStore.getSecondaryKeyStore()!.commitLog = commitLogInstance;

    await AtAccessLogManagerImpl.getInstance().getAccessLog(atSignForTests, accessLogPath: storagePathThisTest);

    final notificationStore = AtNotificationKeystore.getInstance();
    notificationStore.currentAtSign = atSignForTests;
    await notificationStore.init(storagePathThisTest);

    // print(thisTestFileName + ' notify_verb_test doSetUpForSpecificTest COMPLETE for ' + specificTestName);

    return secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  }

  void doTearDownForSpecificTest(String specificTestName) async {
    // TODO See the TODO in doSetUpForSpecificTest above
    // print(thisTestFileName + ' notify_verb_test doTearDownForSpecificTest starting for ' + specificTestName);

    // TODO Need to eliminate some of these singletons
    AtNotificationMap.getInstance().clear();
    // print(thisTestFileName + ' notify_verb_test doTearDownForSpecificTest cleared map');
    await AtNotificationKeystore.getInstance().close();
    // print(thisTestFileName + ' notify_verb_test doTearDownForSpecificTest closed notif keystore');

    String storagePathThisTest = testDataStoragePathRoot + '/' + specificTestName;

    if (Directory(storagePathThisTest).existsSync()) {
      // print(thisTestFileName + ' tearDownAll removing test data directory ' + storagePathThisTest);
      Directory(storagePathThisTest).deleteSync(recursive: true);
    }

    testNames.remove(specificTestName);

    // print(thisTestFileName + ' notify_verb_test doTearDownForSpecificTest COMPLETE for ' + specificTestName);
  }

  group('A group of notify verb regex test', () {
    test('test notify for self atsign', () {
      var verb = Notify();
      var command = 'notify:notifier:persona:@colin:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[FOR_AT_SIGN], 'colin');
    });

    test('test notify for different atsign', () {
      var verb = Notify();
      var command = 'notify:notifier:persona:@bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'colin');
    });
  });

  group('A group of notify accept tests', () {
    test('test notify command accept test', () {
      var command = 'notify:@colin:location@colin';
      var handler = NotifyVerbHandler(null);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test notify command accept test for different atsign', () {
      var command = 'notify:@bob:location@colin';
      var handler = NotifyVerbHandler(null);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test notify command accept negative test without WhomToNotify', () {
      var command = 'notify location@colin';
      var handler = NotifyVerbHandler(null);
      var result = handler.accept(command);
      expect(result, false);
    });

    test('test notify command accept negative test without from AtSign', () {
      var command = 'notify:@colin:location';
      var handler = NotifyVerbHandler(null);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test notify command accept negative test without what to notify', () {
      var command = 'notify:@bob:@colin';
      var handler = NotifyVerbHandler(null);
      var result = handler.accept(command);
      expect(result, true);
    });
  });

  group('A group of notify verb regex - invalid syntax', () {
    test('test notify without whom to notify', () {
      var verb = Notify();
      var command = 'notify:location@alice ';
      var regex = verb.syntax();
      expect(() => getVerbParam(regex, command), throwsA(predicate((dynamic e) => e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test notify key- no from atsign', () {
      var verb = Notify();
      var command = 'notify:@colin:location';
      var regex = verb.syntax();
      var params = getVerbParam(regex, command);
      expect(params['forAtSign'], 'colin');
      expect(params['atKey'], 'location');
    });

    test('test notify with only key', () {
      var verb = Notify();
      var command = 'notify:location';
      var regex = verb.syntax();
      expect(() => getVerbParam(regex, command), throwsA(predicate((dynamic e) => e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test notify key- invalid keyword', () {
      var verb = Notify();
      var command = 'notification:@colin:location@alice';
      var regex = verb.syntax();
      expect(() => getVerbParam(regex, command), throwsA(predicate((dynamic e) => e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test notify verb - no key', () {
      var verb = Notify();
      var command = 'notify:@colin:@alice';
      var regex = verb.syntax();
      expect(() => getVerbParam(regex, command), throwsA(predicate((dynamic e) => e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test notify verb - invalid ttl value', () {
      var notifyVerb = NotifyVerbHandler(null);
      var inboundConnection = InboundConnectionImpl(null, '123');
      var notifyResponse = Response();
      var notifyVerbParams = HashMap<String, String>();
      notifyVerbParams.putIfAbsent('ttl', () => '0');
      expect(() => notifyVerb.processVerb(notifyResponse, notifyVerbParams, inboundConnection), throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify verb - invalid ttb value', () {
      var notifyVerb = NotifyVerbHandler(null);
      var inboundConnection = InboundConnectionImpl(null, '123');
      var notifyResponse = Response();
      var notifyVerbParams = HashMap<String, String>();
      notifyVerbParams.putIfAbsent('ttb', () => '0');
      expect(() => notifyVerb.processVerb(notifyResponse, notifyVerbParams, inboundConnection), throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify verb - ttr = -2 invalid value ', () {
      var notifyVerb = NotifyVerbHandler(null);
      var inboundConnection = InboundConnectionImpl(null, '123');
      var notifyResponse = Response();
      var notifyVerbParams = HashMap<String, String>();
      notifyVerbParams.putIfAbsent('ttr', () => '-2');
      expect(() => notifyVerb.processVerb(notifyResponse, notifyVerbParams, inboundConnection), throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify key- invalid command', () {
      var command = 'notify:location@alice';
      AbstractVerbHandler handler = NotifyVerbHandler(null);
      expect(() => handler.parse(command), throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify key- invalid ccd value', () {
      var command = 'notify:update:ttr:1000:ccd:test:location@alice';
      AbstractVerbHandler handler = NotifyVerbHandler(null);
      expect(() => handler.parse(command), throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });
  });

  group('A group of notify verb handler test', () {
    test('notify verb with upper case', () {
      var verb = Notify();
      var command = 'NOTIFY:notifier:persona:@bob:location@alice';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
    });

    test('notify verb and value with mixed case', () {
      var verb = Notify();
      var command = 'NoTiFy:notifier:persona:@bob:location@alice';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
    });

    test('notify verb with cascade delete is true', () {
      var verb = Notify();
      var command = 'notify:update:notifier:persona:ttr:10000:ccd:true:@bob:location@alice';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[OPERATION], 'update');
      expect(paramsMap[AT_TTR], '10000');
      expect(paramsMap[CCD], 'true');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
    });

    test('notify verb with cascade delete is false', () {
      var verb = Notify();
      var command = 'notify:update:notifier:persona:ttr:10000:ccd:false:@bob:location@alice';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[OPERATION], 'update');
      expect(paramsMap[AT_TTR], '10000');
      expect(paramsMap[CCD], 'false');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
    });
  });

  group('A group of hive related test cases', () {
    test('test notify handler with update operation', () async {
      var specificTestName = 'test_notify_handler_with_update_operation';
      SecondaryKeyStoreManager keyStoreManager = await doSetUpForSpecificTest(specificTestName);

      try {
        SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
        var secretData = AtData();
        secretData.data = 'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
        await keyStore.put('privatekey:at_secret', secretData);
        var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
        AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        var fromVerbParams = HashMap<String, String>();
        fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
        var response = Response();
        await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
        var fromResponse = response.data!.replaceFirst('data:', '');
        var cramVerbParams = HashMap<String, String>();
        var combo = '${secretData.data}$fromResponse';
        var bytes = utf8.encode(combo);
        var digest = sha512.convert(bytes);
        cramVerbParams.putIfAbsent('digest', () => digest.toString());
        var cramVerbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
        var cramResponse = Response();
        await cramVerbHandler.processVerb(cramResponse, cramVerbParams, atConnection);
        var connectionMetadata = atConnection.getMetaData() as InboundConnectionMetadata;
        expect(connectionMetadata.isAuthenticated, true);
        expect(cramResponse.data, 'success');
        //Notify Verb
        var notifyVerbHandler = NotifyVerbHandler(keyStore);
        var notifyResponse = Response();
        var notifyVerbParams = HashMap<String, String>();
        notifyVerbParams.putIfAbsent('operation', () => 'update');
        notifyVerbParams.putIfAbsent('forAtSign', () => '@test_user_1');
        notifyVerbParams.putIfAbsent('atSign', () => '@test_user_1');
        notifyVerbParams.putIfAbsent('atKey', () => 'phone');
        await notifyVerbHandler.processVerb(notifyResponse, notifyVerbParams, atConnection);
        //Notify list verb handler
        var notifyListVerbHandler = NotifyListVerbHandler(keyStore);
        var notifyListResponse = Response();
        var notifyListVerbParams = HashMap<String, String>();
        await notifyListVerbHandler.processVerb(notifyListResponse, notifyListVerbParams, atConnection);
        var notifyData = jsonDecode(notifyListResponse.data!);
        assert(notifyData[0][ID] != null);
        assert(notifyData[0][EPOCH_MILLIS] != null);
        expect(notifyData[0][TO], '@test_user_1');
        expect(notifyData[0][KEY], '@test_user_1:phone@test_user_1');
        expect(notifyData[0][OPERATION], 'update');
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });

    test('test notify handler with delete operation', () async {
      var specificTestName = 'test_notify_handler_with_delete_operation';
      SecondaryKeyStoreManager keyStoreManager = await doSetUpForSpecificTest(specificTestName);
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();

      try {
        var secretData = AtData();
        secretData.data = 'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
        await keyStore.put('privatekey:at_secret', secretData);
        var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
        AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        var fromVerbParams = HashMap<String, String>();
        fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
        var response = Response();
        await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
        var fromResponse = response.data!.replaceFirst('data:', '');
        var cramVerbParams = HashMap<String, String>();
        var combo = '${secretData.data}$fromResponse';
        var bytes = utf8.encode(combo);
        var digest = sha512.convert(bytes);
        cramVerbParams.putIfAbsent('digest', () => digest.toString());
        var cramVerbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
        var cramResponse = Response();
        await cramVerbHandler.processVerb(cramResponse, cramVerbParams, atConnection);
        var connectionMetadata = atConnection.getMetaData() as InboundConnectionMetadata;
        expect(connectionMetadata.isAuthenticated, true);
        expect(cramResponse.data, 'success');
        //Notify Verb
        var notifyVerbHandler = NotifyVerbHandler(keyStore);
        var notifyResponse = Response();
        var notifyVerbParams = HashMap<String, String>();
        notifyVerbParams.putIfAbsent('operation', () => 'delete');
        notifyVerbParams.putIfAbsent('forAtSign', () => '@test_user_1');
        notifyVerbParams.putIfAbsent('atSign', () => '@test_user_1');
        notifyVerbParams.putIfAbsent('atKey', () => 'phone');
        await notifyVerbHandler.processVerb(notifyResponse, notifyVerbParams, atConnection);
        //Notify list verb handler
        var notifyListVerbHandler = NotifyListVerbHandler(keyStore);
        var notifyListResponse = Response();
        var notifyListVerbParams = HashMap<String, String>();
        await notifyListVerbHandler.processVerb(notifyListResponse, notifyListVerbParams, atConnection);
        var notifyData = jsonDecode(notifyListResponse.data!);
        assert(notifyData[0][ID] != null);
        assert(notifyData[0][EPOCH_MILLIS] != null);
        expect(notifyData[0][TO], '@test_user_1');
        expect(notifyData[0][KEY], '@test_user_1:phone@test_user_1');
        expect(notifyData[0][OPERATION], 'delete');
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });
  });

  group('A group of notify verb test', () {
    test('A test case to verify enqueuing error notifications increments retry count', () async {
      var specificTestName = 'test_enqueue_error_notifications_increments_retry_count';
      await doSetUpForSpecificTest(specificTestName);

      try {
        var atNotification1 = (AtNotificationBuilder()
          ..id = 'abc'
          ..fromAtSign = '@test_user_1'
          ..notificationDateTime = DateTime.now()
          ..toAtSign = '@alice'
          ..notification = 'key-1'
          ..type = NotificationType.sent
          ..opType = OperationType.update
          ..messageType = MessageType.key
          ..expiresAt = null
          ..priority = NotificationPriority.medium
          ..notificationStatus = NotificationStatus.errored
          ..retryCount = 0)
            .build();
        var queueManager = QueueManager.getInstance();
        queueManager.enqueue(atNotification1);
        var response = queueManager.dequeue('@alice');
        late AtNotification atNotification;
        if (response.moveNext()) {
          atNotification = response.current;
        }
        expect('abc', atNotification.id);
        expect('@test_user_1', atNotification.fromAtSign);
        expect('@alice', atNotification.toAtSign);
        expect(NotificationPriority.low, atNotification.priority);
        expect('key-1', atNotification.notification);
        expect(1, atNotification.retryCount);
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });
  });

  group('A group of tests to compute notifications wait time', () {
    test('A test to compute notifications with equal delay, @sign with highest priority is dequeued', () async {
      var specificTestName = 'test_compute_notifications_wait_time_1';
      await doSetUpForSpecificTest(specificTestName);

      try {
        var atNotification1 = (AtNotificationBuilder()
              ..id = '123'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(minutes: 4))
              ..toAtSign = '@bob'
              ..notification = 'key-1'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.medium
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'all'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var atNotification2 = (AtNotificationBuilder()
              ..id = '124'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(minutes: 4))
              ..toAtSign = '@alice'
              ..notification = 'key-2'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.high
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'all'
              ..notifier = 'location'
              ..depth = 2)
            .build();

        var notificationMap = AtNotificationMap.getInstance();
        notificationMap.add(atNotification1);
        notificationMap.add(atNotification2);
        var atsignIterator = AtNotificationMap.getInstance().getAtSignToNotify(1);
        while (atsignIterator.moveNext()) {
          expect(atsignIterator.current, '@alice');
        }
        AtNotificationMap.getInstance().clear();
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });

    test('A test to verify lowest atsign with highest waiting time gets out than highest priority', () async {
      var specificTestName = 'test_compute_notifications_wait_time_2';
      await doSetUpForSpecificTest(specificTestName);

      try {
        var atNotification1 = (AtNotificationBuilder()
              ..id = '123'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(minutes: 10))
              ..toAtSign = '@bob'
              ..notification = 'key-1'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'all'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var atNotification2 = (AtNotificationBuilder()
              ..id = '123'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(minutes: 1))
              ..toAtSign = '@alice'
              ..notification = 'key-2'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.high
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'all'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var notificationMap = AtNotificationMap.getInstance();
        notificationMap.add(atNotification1);
        notificationMap.add(atNotification2);
        var atsignIterator = AtNotificationMap.getInstance().getAtSignToNotify(1);
        while (atsignIterator.moveNext()) {
          expect(atsignIterator.current, '@bob');
        }
        AtNotificationMap.getInstance().clear();
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });

    test('A test case to verify notifications with strategy all with equal priorities are stored as per the wait time', () async {
      var specificTestName = 'test_notification_strategy_1';
      await doSetUpForSpecificTest(specificTestName);

      try {
        var atNotification1 = (AtNotificationBuilder()
              ..id = '123'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(minutes: 1))
              ..toAtSign = '@bob'
              ..notification = 'key-1'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'all'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var atNotification2 = (AtNotificationBuilder()
              ..id = '124'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(minutes: 2))
              ..toAtSign = '@bob'
              ..notification = 'key-2'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'all'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var notificationMap = AtNotificationMap.getInstance();
        notificationMap.add(atNotification1);
        notificationMap.add(atNotification2);
        var atsignIterator = notificationMap.getAtSignToNotify(1);
        var atNotificationList = [];
        // ignore: prefer_typing_uninitialized_variables
        var atSign;
        while (atsignIterator.moveNext()) {
          atSign = atsignIterator.current;
        }
        var itr = QueueManager.getInstance().dequeue(atSign);
        while (itr.moveNext()) {
          atNotificationList.add(itr.current);
        }
        expect('124', atNotificationList[0].id);
        expect('123', atNotificationList[1].id);
        AtNotificationMap.getInstance().clear();
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });

    test('A test case to verify only the latest notification is stored', () async {
      var specificTestName = 'test_notification_strategy_2';
      await doSetUpForSpecificTest(specificTestName);

      try {
        var atNotification1 = (AtNotificationBuilder()
              ..id = '123'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now()
              ..toAtSign = '@bob'
              ..notification = 'key-1'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'latest'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var atNotification2 = (AtNotificationBuilder()
              ..id = '124'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now()
              ..toAtSign = '@bob'
              ..notification = 'key-2'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'latest'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var notificationMap = AtNotificationMap.getInstance();
        notificationMap.add(atNotification1);
        notificationMap.add(atNotification2);
        var atsignIterator = notificationMap.getAtSignToNotify(1);
        var atNotificationList = [];
        // ignore: prefer_typing_uninitialized_variables
        var atSign;
        while (atsignIterator.moveNext()) {
          atSign = atsignIterator.current;
        }
        var itr = QueueManager.getInstance().dequeue(atSign);
        while (itr.moveNext()) {
          atNotificationList.add(itr.current);
        }
        expect('124', atNotificationList[0].id);
        AtNotificationMap.getInstance().clear();
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });

    test('When latest N, when N = 2', () async {
      var specificTestName = 'test_notification_strategy_3';
      await doSetUpForSpecificTest(specificTestName);

      try {
        var atNotification1 = (AtNotificationBuilder()
              ..id = '123'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(seconds: 3))
              ..toAtSign = '@bob'
              ..notification = 'key-1'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'latest'
              ..notifier = 'persona'
              ..depth = 2)
            .build();

        var atNotification2 = (AtNotificationBuilder()
              ..id = '124'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(seconds: 2))
              ..toAtSign = '@bob'
              ..notification = 'key-2'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'latest'
              ..notifier = 'persona'
              ..depth = 2)
            .build();

        var atNotification3 = (AtNotificationBuilder()
              ..id = '125'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(seconds: 1))
              ..toAtSign = '@bob'
              ..notification = 'key-3'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'latest'
              ..notifier = 'persona'
              ..depth = 2)
            .build();
        var notificationMap = AtNotificationMap.getInstance();

        notificationMap.add(atNotification1);
        notificationMap.add(atNotification2);
        notificationMap.add(atNotification3);
        var atsignIterator = notificationMap.getAtSignToNotify(1);
        var atNotificationList = [];
        // ignore: prefer_typing_uninitialized_variables
        var atSign;
        while (atsignIterator.moveNext()) {
          atSign = atsignIterator.current;
        }
        var itr = QueueManager.getInstance().dequeue(atSign);
        while (itr.moveNext()) {
          atNotificationList.add(itr.current);
        }
        expect('124', atNotificationList[0].id);
        expect('125', atNotificationList[1].id);
        AtNotificationMap.getInstance().clear();
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });

    test('Change in notifierId should increase the queue size and retain the old notifications as per priority', () async {
      var specificTestName = 'test_notification_strategy_4';
      await doSetUpForSpecificTest(specificTestName);

      try {
        var atNotification1 = (AtNotificationBuilder()
              ..id = '123'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(seconds: 3))
              ..toAtSign = '@bob'
              ..notification = 'key-1'
              ..type = NotificationType.sent
              ..opType = OperationType.update
              ..messageType = MessageType.key
              ..expiresAt = null
              ..priority = NotificationPriority.low
              ..notificationStatus = NotificationStatus.queued
              ..retryCount = 0
              ..strategy = 'latest'
              ..notifier = 'persona'
              ..depth = 1)
            .build();

        var atNotification2 = (AtNotificationBuilder()
              ..id = '124'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(seconds: 2))
              ..toAtSign = '@bob'
              ..notification = 'key-2'
              ..type = NotificationType.sent
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

        var atNotification3 = (AtNotificationBuilder()
              ..id = '125'
              ..fromAtSign = '@test_user_1'
              ..notificationDateTime = DateTime.now().subtract(Duration(seconds: 1))
              ..toAtSign = '@bob'
              ..notification = 'key-3'
              ..type = NotificationType.sent
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
        var notificationMap = AtNotificationMap.getInstance();
        notificationMap.add(atNotification1);
        notificationMap.add(atNotification2);
        notificationMap.add(atNotification3);
        var atsignIterator = notificationMap.getAtSignToNotify(1);
        var atNotificationList = [];
        // ignore: prefer_typing_uninitialized_variables
        var atSign;
        while (atsignIterator.moveNext()) {
          atSign = atsignIterator.current;
        }
        var itr = QueueManager.getInstance().dequeue(atSign);
        while (itr.moveNext()) {
          atNotificationList.add(itr.current);
        }
        expect('123', atNotificationList[0].id);
        expect('124', atNotificationList[1].id);
        expect('125', atNotificationList[2].id);
        AtNotificationMap.getInstance().clear();
      } finally {
        doTearDownForSpecificTest(specificTestName);
      }
    });
  });
}

