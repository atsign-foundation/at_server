import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_fetch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

class MockOutboundClientManager extends Mock implements OutboundClientManager {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();

  var storageDir = '${Directory.current.path}/test/hive';
  late SecondaryKeyStoreManager keyStoreManager;

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
      var handler = NotifyVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test notify command accept test for different atsign', () {
      var command = 'notify:@bob:location@colin';
      var handler = NotifyVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test notify command accept negative test without WhomToNotify', () {
      var command = 'notify location@colin';
      var handler = NotifyVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, false);
    });

    test('test notify command accept negative test without from AtSign', () {
      var command = 'notify:@colin:location';
      var handler = NotifyVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test notify command accept negative test without what to notify', () {
      var command = 'notify:@bob:@colin';
      var handler = NotifyVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });
  });

  group('A group of notify verb regex - invalid syntax', () {
    test('test notify without whom to notify', () {
      var verb = Notify();
      var command = 'notify:location@alice ';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
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
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test notify key- invalid keyword', () {
      var verb = Notify();
      var command = 'notification:@colin:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test notify verb - no key', () {
      var verb = Notify();
      var command = 'notify:@colin:@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test notify verb - invalid ttl value', () {
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var notifyVerb = NotifyVerbHandler(mockKeyStore);
      var inboundConnection = InboundConnectionImpl(null, '123');
      inboundConnection.metaData = InboundConnectionMetadata()
        ..isAuthenticated = true;
      var notifyResponse = Response();
      var notifyVerbParams = HashMap<String, String>();
      notifyVerbParams.putIfAbsent('ttl', () => '-1');
      notifyVerbParams.putIfAbsent(FOR_AT_SIGN, () => '@bob');
      notifyVerbParams.putIfAbsent(AT_KEY, () => 'phone');
      notifyVerbParams.putIfAbsent(AT_SIGN, () => '@alice');

      expect(
          () => notifyVerb.processVerb(
              notifyResponse, notifyVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify verb - invalid ttb value', () {
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var notifyVerb = NotifyVerbHandler(mockKeyStore);
      var inboundConnection = InboundConnectionImpl(null, '123');
      inboundConnection.metaData = InboundConnectionMetadata()
        ..isAuthenticated = true;
      var notifyResponse = Response();
      var notifyVerbParams = HashMap<String, String>();
      notifyVerbParams.putIfAbsent('ttb', () => '-1');
      notifyVerbParams.putIfAbsent(FOR_AT_SIGN, () => '@bob');
      notifyVerbParams.putIfAbsent(AT_SIGN, () => '@alice');
      notifyVerbParams.putIfAbsent(AT_KEY, () => 'phone');
      expect(
          () => notifyVerb.processVerb(
              notifyResponse, notifyVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify verb - ttr = -2 invalid value ', () {
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var notifyVerb = NotifyVerbHandler(mockKeyStore);
      var inboundConnection = InboundConnectionImpl(null, '123');
      inboundConnection.metaData = InboundConnectionMetadata()
        ..isAuthenticated = true;
      var notifyResponse = Response();
      var notifyVerbParams = HashMap<String, String>();
      notifyVerbParams.putIfAbsent('ttr', () => '-2');
      notifyVerbParams.putIfAbsent(FOR_AT_SIGN, () => '@bob');
      notifyVerbParams.putIfAbsent(AT_SIGN, () => '@alice');
      notifyVerbParams.putIfAbsent(AT_KEY, () => 'phone');
      expect(
          () => notifyVerb.processVerb(
              notifyResponse, notifyVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify key- invalid command', () {
      var command = 'notify:location@alice';
      AbstractVerbHandler handler = NotifyVerbHandler(mockKeyStore);
      expect(() => handler.parse(command),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test notify key- invalid ccd value', () {
      var command = 'notify:update:ttr:1000:ccd:test:location@alice';
      AbstractVerbHandler handler = NotifyVerbHandler(mockKeyStore);
      expect(() => handler.parse(command),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
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
      var command =
          'notify:update:notifier:persona:ttr:10000:ccd:true:@bob:location@alice';
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
      var command =
          'notify:update:notifier:persona:ttr:10000:ccd:false:@bob:location@alice';
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
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));
    test('test notify handler with update operation', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
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
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
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
      await notifyVerbHandler.processVerb(
          notifyResponse, notifyVerbParams, atConnection);
      //Notify list verb handler
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStore, mockOutboundClientManager);
      var notifyListResponse = Response();
      var notifyListVerbParams = HashMap<String, String>();
      await notifyListVerbHandler.processVerb(
          notifyListResponse, notifyListVerbParams, atConnection);
      var notifyData = jsonDecode(notifyListResponse.data!);
      assert(notifyData[0][ID] != null);
      assert(notifyData[0][EPOCH_MILLIS] != null);
      expect(notifyData[0][TO], '@test_user_1');
      expect(notifyData[0][KEY], '@test_user_1:phone@test_user_1');
      expect(notifyData[0][OPERATION], 'update');
    });

    test('test notify handler with delete operation', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
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
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
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
      await notifyVerbHandler.processVerb(
          notifyResponse, notifyVerbParams, atConnection);
      //Notify list verb handler
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStore, mockOutboundClientManager);
      var notifyListResponse = Response();
      var notifyListVerbParams = HashMap<String, String>();
      await notifyListVerbHandler.processVerb(
          notifyListResponse, notifyListVerbParams, atConnection);
      var notifyData = jsonDecode(notifyListResponse.data!);
      assert(notifyData[0][ID] != null);
      assert(notifyData[0][EPOCH_MILLIS] != null);
      expect(notifyData[0][TO], '@test_user_1');
      expect(notifyData[0][KEY], '@test_user_1:phone@test_user_1');
      expect(notifyData[0][OPERATION], 'delete');
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of notify verb test', () {
    setUp(() async => await setUpFunc(storageDir));
    test(
        'A test case to verify enqueuing error notifications increments retry count',
        () async {
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
      expect(atNotification.id, 'abc');
      expect(atNotification.fromAtSign, '@test_user_1');
      expect(atNotification.toAtSign, '@alice');
      expect(atNotification.priority, NotificationPriority.low);
      expect(atNotification.notification, 'key-1');
      expect(atNotification.retryCount, 1);
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests to compute notifications wait time', () {
    test(
        'A test to compute notifications with equal delay, @sign with highest priority is dequeued',
        () {
      var atNotification1 = (AtNotificationBuilder()
            ..id = '123'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime =
                DateTime.now().subtract(Duration(minutes: 4))
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
            ..notificationDateTime =
                DateTime.now().subtract(Duration(minutes: 4))
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
    });

    test(
        'A test to verify lowest atsign with highest waiting time gets out than highest priority',
        () {
      var atNotification1 = (AtNotificationBuilder()
            ..id = '123'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime =
                DateTime.now().subtract(Duration(minutes: 10))
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
            ..notificationDateTime =
                DateTime.now().subtract(Duration(minutes: 1))
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
    });
  });
  group('A group of tests on notification strategy - all', () {
    test(
        'A test case to verify notifications with strategy all with equal priorities are stored as per the wait time',
        () {
      var atNotification1 = (AtNotificationBuilder()
            ..id = '123'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime =
                DateTime.now().subtract(Duration(minutes: 1))
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
            ..notificationDateTime =
                DateTime.now().subtract(Duration(minutes: 2))
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
      String? atsign;
      while (atsignIterator.moveNext()) {
        atsign = atsignIterator.current;
      }
      var itr = QueueManager.getInstance().dequeue(atsign);
      while (itr.moveNext()) {
        atNotificationList.add(itr.current);
      }
      expect(atNotificationList[0].id, '124');
      expect(atNotificationList[1].id, '123');
      AtNotificationMap.getInstance().clear();
    });
  });
  group('A group of test cases on notification strategy - latest', () {
    test('A test case to verify only the latest notification is stored', () {
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
      String? atsign;
      while (atsignIterator.moveNext()) {
        atsign = atsignIterator.current;
      }
      var itr = QueueManager.getInstance().dequeue(atsign);
      while (itr.moveNext()) {
        atNotificationList.add(itr.current);
      }
      expect(atNotificationList[0].id, '124');
      AtNotificationMap.getInstance().clear();
    });

    test('When latest N, when N = 2', () {
      var atNotification1 = (AtNotificationBuilder()
            ..id = '123'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 3))
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
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 2))
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
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 1))
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
      String? atsign;
      while (atsignIterator.moveNext()) {
        atsign = atsignIterator.current;
      }
      var itr = QueueManager.getInstance().dequeue(atsign);
      while (itr.moveNext()) {
        atNotificationList.add(itr.current);
      }
      expect(atNotificationList[0].id, '124');
      expect(atNotificationList[1].id, '125');
      AtNotificationMap.getInstance().clear();
    });

    test(
        'Change in notifierId should increase the queue size and retain the old notifications as per priority',
        () {
      var atNotification1 = (AtNotificationBuilder()
            ..id = '123'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 3))
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
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 2))
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
            ..notificationDateTime =
                DateTime.now().subtract(Duration(seconds: 1))
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
      String? atSign;
      while (atsignIterator.moveNext()) {
        atSign = atsignIterator.current;
      }
      var itr = QueueManager.getInstance().dequeue(atSign);
      while (itr.moveNext()) {
        atNotificationList.add(itr.current);
      }
      expect(atNotificationList[0].id, '123');
      expect(atNotificationList[1].id, '124');
      expect(atNotificationList[2].id, '125');
      AtNotificationMap.getInstance().clear();
    });
  });
  group(
      'A group of tests to verify public key checksum and shared key on metadata',
      () {
    test('notify command accept test for pubKeyCS and sharedKeyEnc', () {
      var command = 'notify:sharedKeyEnc:abc:pubKeyCS:123@bob:location@colin';
      var handler = NotifyVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });
    test('verify pubKeyCS and sharedKeyEnc in metadata', () async {
      final atMetaData = AtMetaData()
        ..pubKeyCS = '123'
        ..sharedKeyEnc = 'abc';
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
            ..priority = NotificationPriority.high
            ..atMetaData = atMetaData)
          .build();
      var queueManager = QueueManager.getInstance();
      queueManager.enqueue(atNotification1);
      var response = queueManager.dequeue('@alice');
      late AtNotification atNotification;
      if (response.moveNext()) {
        atNotification = response.current;
      }
      expect(atNotification.id, 'abc');
      expect(
        atNotification.fromAtSign,
        '@test_user_1',
      );
      expect(
        atNotification.toAtSign,
        '@alice',
      );
      expect(atNotification.notification, 'key-1');
      expect(atNotification.atMetadata, isNotNull);
      expect(atNotification.atMetadata!.pubKeyCS, '123');
      expect(atNotification.atMetadata!.sharedKeyEnc, 'abc');
    });
  });

  group('A group of notification to verify date time', () {
    late NotifyVerbHandler notifyVerbHandler;
    late Response notifyResponse;
    late NotifyFetchVerbHandler notifyFetch;
    late InboundConnectionImpl atConnection;
    HashMap<String, String> firstNotificationVerbParams =
        HashMap<String, String>();
    HashMap<String, String> secondNotificationVerbParams =
        HashMap<String, String>();

    setUp(() async {
      keyStoreManager = await setUpFunc(storageDir);
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      notifyVerbHandler = NotifyVerbHandler(keyStore);
      notifyResponse = Response();
      notifyFetch = NotifyFetchVerbHandler(keyStore);

      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      atConnection = InboundConnectionImpl(null, inBoundSessionId);

      // first notification
      firstNotificationVerbParams.putIfAbsent('id', () => 'abc-123');
      firstNotificationVerbParams.putIfAbsent('operation', () => 'update');
      firstNotificationVerbParams.putIfAbsent('atSign', () => '@test_user_1');
      firstNotificationVerbParams.putIfAbsent('atKey', () => 'phone');
      firstNotificationVerbParams.putIfAbsent(
          FOR_AT_SIGN, () => '@test_user_2');

      // second notification
      secondNotificationVerbParams.putIfAbsent('id', () => 'xyz-123');
      secondNotificationVerbParams.putIfAbsent('operation', () => 'update');
      secondNotificationVerbParams.putIfAbsent('atSign', () => '@test_user_1');
      secondNotificationVerbParams.putIfAbsent('atKey', () => 'otp');
    });

    test('test to verify notification date time stored for self', () async {
      atConnection.metaData.isAuthenticated = true;
      // process first notification
      firstNotificationVerbParams.putIfAbsent(
          'forAtSign', () => '@test_user_1');
      await notifyVerbHandler.processVerb(
          notifyResponse, firstNotificationVerbParams, atConnection);
      // store current date time to capture the difference
      var currentDateTime = DateTime.now();
      await Future.delayed(Duration(milliseconds: 50));
      // process second notification
      secondNotificationVerbParams.putIfAbsent(
          'forAtSign', () => '@test_user_1');
      await notifyVerbHandler.processVerb(
          notifyResponse, secondNotificationVerbParams, atConnection);
      // fetch second notification
      HashMap<String, String> notifyFetchVerbParams = HashMap();
      notifyFetchVerbParams.putIfAbsent('notificationId', () => 'xyz-123');
      await notifyFetch.processVerb(
          notifyResponse, notifyFetchVerbParams, atConnection);
      var decodedNotifyFetchResponse = jsonDecode(notifyResponse.data!);
      var secondNotificationDateTime =
          decodedNotifyFetchResponse['notificationDateTime'];
      expect(
          DateTime.parse(secondNotificationDateTime).microsecondsSinceEpoch >
              currentDateTime.microsecondsSinceEpoch,
          true);
    });

    test('test to verify notification date time on receiver side', () async {
      atConnection.metaData.isPolAuthenticated = true;
      (atConnection.metaData as InboundConnectionMetadata).fromAtSign =
          '@test_user1';
      // process first notification
      await notifyVerbHandler.processVerb(
          notifyResponse, firstNotificationVerbParams, atConnection);
      // store current date time to capture the difference
      var currentDateTime = DateTime.now().millisecondsSinceEpoch;
      await Future.delayed(Duration(milliseconds: 50));
      // process second notification
      secondNotificationVerbParams.putIfAbsent(
          'forAtSign', () => '@test_user_1');
      await notifyVerbHandler.processVerb(
          notifyResponse, secondNotificationVerbParams, atConnection);
      // fetch second notification
      HashMap<String, String> notifyFetchVerbParams = HashMap();
      notifyFetchVerbParams.putIfAbsent('notificationId', () => 'xyz-123');
      await notifyFetch.processVerb(
          notifyResponse, notifyFetchVerbParams, atConnection);
      var decodedNotifyFetchResponse = jsonDecode(notifyResponse.data!);
      var secondNotificationDateTime =
          decodedNotifyFetchResponse['notificationDateTime'];
      expect(
          DateTime.parse(secondNotificationDateTime).millisecondsSinceEpoch >
              currentDateTime,
          true);
    });

    group('A group of test to validate notification verb params', () {
      late NotifyVerbHandler notifyVerbHandler;
      setUp(() async {
        keyStoreManager = await setUpFunc(storageDir);
        SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
        notifyVerbHandler = NotifyVerbHandler(keyStore);
      });
      // tests to validate message type
      test(
          'A test to validate messageType.key is returned when key string is passed',
          () {
        expect(notifyVerbHandler.getMessageType('key'), MessageType.key);
        expect(notifyVerbHandler.getMessageType('KEY'), MessageType.key);
      });

      test(
          'A test to validate messageType.text is returned when text string is passed',
          () {
        expect(notifyVerbHandler.getMessageType('text'), MessageType.text);
        expect(notifyVerbHandler.getMessageType('TEXT'), MessageType.text);
      });

      test(
          'A test to validate default messageType is returned when null is passed',
          () {
        expect(notifyVerbHandler.getMessageType(null), MessageType.key);
        expect(notifyVerbHandler.getMessageType(''), MessageType.key);
      });

      // tests to validate operation type
      test(
          'A test to validate operationType.update is returned when update string is passed',
          () {
        expect(
            notifyVerbHandler.getOperationType('update'), OperationType.update);
        expect(
            notifyVerbHandler.getOperationType('UPDATE'), OperationType.update);
      });

      test(
          'A test to validate operationType.delete is returned when delete string is passed',
          () {
        expect(
            notifyVerbHandler.getOperationType('delete'), OperationType.delete);
        expect(
            notifyVerbHandler.getOperationType('DELETE'), OperationType.delete);
      });

      test(
          'A test to validate default operationType is returned when null or empty string is passed',
          () {
        expect(notifyVerbHandler.getOperationType(null), OperationType.update);
        expect(notifyVerbHandler.getOperationType(''), OperationType.update);
      });

      // test to validate notification expiry duration
      test(
          'A test to validate default notification expiry duration is returned when null or 0 is passed',
          () {
        expect(
            notifyVerbHandler.getNotificationExpiryInMillis(null),
            Duration(minutes: AtSecondaryConfig.notificationExpiryInMins)
                .inMilliseconds);
        expect(
            notifyVerbHandler.getNotificationExpiryInMillis('0'),
            Duration(minutes: AtSecondaryConfig.notificationExpiryInMins)
                .inMilliseconds);
      });

      test(
          'A test to validate notification expiry duration positive integer is passed',
          () {
        expect(notifyVerbHandler.getNotificationExpiryInMillis('30'), 30);
      });

      test(
          'A test to assert exception when negative integer is passed to notification expiry duration ',
          () {
        expect(() => notifyVerbHandler.getNotificationExpiryInMillis('-30'),
            throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
      });

      test(
          'A test to assert exception when character is passed to notification expiry duration ',
          () {
        expect(() => notifyVerbHandler.getNotificationExpiryInMillis('abc'),
            throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
      });
    });
    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir, {String? atsign}) async {
  AtSecondaryServerImpl.getInstance().currentAtSign = atsign ?? '@test_user_1';
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign)!;
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
  await AtNotificationKeystore.getInstance().close();
  if (isExists) {
    await Directory('test/hive').delete(recursive: true);
  }
}
