import 'dart:convert';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/stats_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_secondary/src/verb/metrics/metrics_impl.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';
import 'package:uuid/uuid.dart';
import 'notify_verb_test.dart';
import 'package:mocktail/mocktail.dart';

import 'test_utils.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

class MockOutboundClientManager extends Mock implements OutboundClientManager {}

class MockAtCacheManager extends Mock implements AtCacheManager {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
  AtCacheManager mockAtCacheManager = MockAtCacheManager();

  group('A group of stats verb tests', () {
    test('test stats getVerb', () {
      var handler = StatsVerbHandler(mockKeyStore);
      var verb = handler.getVerb();
      expect(verb is Stats, true);
    });

    test('test stats command accept test', () {
      var command = 'stats:1';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test stats with regex', () {
      var command = 'stats:3:.me';
      var verb = Stats();
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['statId'], ':3');
      expect(paramsMap['regex'], '.me');
    });

    test('test stats command accept test with comma separated values', () {
      var command = 'stats:1,2,3';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test stats key- invalid keyword', () {
      var verb = Stats();
      var command = 'staats';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test stats key with regex - invalid keyword', () {
      var verb = Stats();
      var command = 'stats:2:me';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test stats verb - upper case', () {
      var command = 'STATS';
      command = SecondaryUtil.convertCommand(command);
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test stats verb - space in between', () {
      var verb = Stats();
      var command = 'st ats';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test stats verb - invalid syntax', () {
      var command = 'statsn';
      var inbound = InboundConnectionImpl(null, null);
      var defaultVerbExecutor = DefaultVerbExecutor();
      var defaultVerbHandlerManager = DefaultVerbHandlerManager(
          mockKeyStore,
          mockOutboundClientManager,
          mockAtCacheManager,
          StatsNotificationService.getInstance(),
          NotificationManager.getInstance());

      expect(
          () => defaultVerbExecutor.execute(
              command, inbound, defaultVerbHandlerManager),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });
  });
  group('A group of notificationStats verb tests', () {
    SecondaryKeyStoreManager? keyStoreManager;
    setUp(() async => keyStoreManager = await setUpFunc(
        '${Directory.current.path}/test/hive',
        atsign: '@alice'));
    // test for Notification Stats
    test('notification stats command accept test', () {
      var command = 'stats:11';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('the name of the notificationStats', () async {
      var metric = NotificationsMetricImpl.getInstance();
      String name = metric.getName();
      expect(name, 'NotificationCount');
    });

    test('the value of the notificationStats', () async {
      Map<String, dynamic> metricsMap = <String, dynamic>{
        'total': 0,
        'type': <String, int>{
          'sent': 0,
          'received': 0,
        },
        'status': <String, int>{
          'delivered': 0,
          'failed': 0,
          'queued': 0,
        },
        'operations': <String, int>{
          'update': 0,
          'delete': 0,
        },
        'messageType': <String, int>{
          'key': 0,
          'text': 0,
        },
        'createdOn': 0,
      };
      var notifyListVerbHandler = NotifyListVerbHandler(
          keyStoreManager!.getKeyStore(), mockOutboundClientManager);
      var testNotification = (AtNotificationBuilder()
            ..id = '1031'
            ..fromAtSign = '@bob'
            ..notificationDateTime =
                DateTime.now().subtract(const Duration(days: 1))
            ..toAtSign = '@alice'
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
      var testNotification2 = (AtNotificationBuilder()
            ..id = '1032'
            ..fromAtSign = '@bob'
            ..notificationDateTime =
                DateTime.now().subtract(const Duration(days: 1))
            ..toAtSign = '@alice'
            ..notification = 'key-2'
            ..type = NotificationType.received
            ..opType = OperationType.delete
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.queued
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();
      var testNotification3 = (AtNotificationBuilder()
            ..id = '1033'
            ..fromAtSign = '@bob'
            ..notificationDateTime =
                DateTime.now().subtract(const Duration(days: 1))
            ..toAtSign = '@alice'
            ..notification = 'key-2'
            ..type = NotificationType.sent
            ..opType = OperationType.update
            ..messageType = MessageType.text
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.errored
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();
      var testNotification4 = (AtNotificationBuilder()
            ..id = '1034'
            ..fromAtSign = '@bob'
            ..notificationDateTime =
                DateTime.now().subtract(const Duration(days: 1))
            ..toAtSign = '@alice'
            ..notification = 'key-2'
            ..type = NotificationType.received
            ..opType = OperationType.update
            ..messageType = MessageType.key
            ..expiresAt = null
            ..priority = NotificationPriority.low
            ..notificationStatus = NotificationStatus.delivered
            ..retryCount = 0
            ..strategy = 'latest'
            ..notifier = 'persona'
            ..depth = 3)
          .build();
      var metadata = InboundConnectionMetadata()
        ..fromAtSign = '@bob'
        ..isAuthenticated = true;
      await AtNotificationKeystore.getInstance().put('1031', testNotification);
      await AtNotificationKeystore.getInstance().put('1032', testNotification2);
      await AtNotificationKeystore.getInstance().put('1033', testNotification3);
      await AtNotificationKeystore.getInstance().put('1034', testNotification4);
      var verb = Notify();
      var command = 'notify:update:ttr:-1:@alice:city@bob:vijayawada';
      var command2 = 'notify:delete:ttr:-1:@alice:city@bob:vijayawada';
      var command3 = 'notify:update:ttr:-1:@alice:city@bob:vijayawada';
      var command4 = 'notify:update:ttr:-1:@alice:city@bob:vijayawada';
      command = SecondaryUtil.convertCommand(command);
      command2 = SecondaryUtil.convertCommand(command2);
      command3 = SecondaryUtil.convertCommand(command3);
      command4 = SecondaryUtil.convertCommand(command4);
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var verbParams2 = getVerbParam(regex, command2);
      var verbParams3 = getVerbParam(regex, command3);
      var verbParams4 = getVerbParam(regex, command4);
      var atConnection = InboundConnectionImpl(null, '12345')
        ..metaData = metadata;
      var response = Response();
      await notifyListVerbHandler.processVerb(
          response, verbParams, atConnection);
      await notifyListVerbHandler.processVerb(
          response, verbParams2, atConnection);
      await notifyListVerbHandler.processVerb(
          response, verbParams3, atConnection);
      await notifyListVerbHandler.processVerb(
          response, verbParams4, atConnection);
      metricsMap = await NotificationsMetricImpl.getInstance()
          .getNotificationStats(metricsMap);
      expect(metricsMap['total'], 4);
      expect(metricsMap['type']['sent'], 2);
      expect(metricsMap['type']['received'], 2);
      expect(metricsMap['status']['delivered'], 1);
      expect(metricsMap['status']['failed'], 1);
      expect(metricsMap['status']['queued'], 2);
      expect(metricsMap['operations']['update'], 3);
      expect(metricsMap['operations']['delete'], 1);
      expect(metricsMap['messageType']['key'], 3);
      expect(metricsMap['messageType']['text'], 1);
      expect(metricsMap['createdOn'] is int, true);
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of commitLogCompactionStats verb tests', () {
    SecondaryKeyStoreManager? keyStoreManager;
    setUp(() async => keyStoreManager = await setUpFunc(
        '${Directory.current.path}/test/hive',
        atsign: '@alice'));

    test('commitLogCompactionStats command accept test', () {
      var command = 'stats:12';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test name returned for commitLogCompaction Stats', () async {
      var commitLogInstance = CommitLogCompactionStats.getInstance();
      String name = commitLogInstance.getName();
      expect(name, 'CommitLogCompactionStats');
    });

    test('commit Log stats get value test', () async {
      AtCompactionStats atCompactionStats = AtCompactionStats();
      var keyStore = keyStoreManager?.getKeyStore();

      atCompactionStats.compactionDurationInMills = 1000;
      atCompactionStats.deletedKeysCount = 41;
      atCompactionStats.lastCompactionRun = DateTime.now();
      atCompactionStats.postCompactionEntriesCount = 92;
      atCompactionStats.preCompactionEntriesCount = 96;
      atCompactionStats.atCompactionType =
          (await AtAccessLogManagerImpl.getInstance().getAccessLog('@alice'))!
              .toString();
      await keyStore?.put(commitLogCompactionKey,
          AtData()..data = jsonEncode(atCompactionStats));

      var atData = await CommitLogCompactionStats.getInstance().getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(
          decodedData[AtCompactionConstants.deletedKeysCount].toString(), '41');
      expect(
          decodedData[AtCompactionConstants.postCompactionEntriesCount]
              .toString(),
          '92');
      expect(
          decodedData[AtCompactionConstants.preCompactionEntriesCount]
              .toString(),
          '96');
      expect(
          decodedData[AtCompactionConstants.compactionDurationInMills]
              .toString(),
          '1000');
    });
  });

  group('A group of accessLogCompactionStats verb tests', () {
    SecondaryKeyStoreManager? keyStoreManager;
    setUp(() async => keyStoreManager = await setUpFunc(
        '${Directory.current.path}/test/hive',
        atsign: '@alice'));

    test('accessLogCompactionStats command acceptance test', () {
      var command = 'stats:13';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('name returned for accessLogCompaction Stats test', () async {
      var accessLogInstance = AccessLogCompactionStats.getInstance();
      String name = accessLogInstance.getName();
      expect(name, 'AccessLogCompactionStats');
    });

    test('accessLogCompactionStats getValue test', () async {
      AtCompactionStats atCompactionStats = AtCompactionStats();
      var keyStore = keyStoreManager?.getKeyStore();

      atCompactionStats.compactionDurationInMills = 10000;
      atCompactionStats.deletedKeysCount = 431;
      atCompactionStats.lastCompactionRun = DateTime.now();
      atCompactionStats.postCompactionEntriesCount = 902;
      atCompactionStats.preCompactionEntriesCount = 906;
      atCompactionStats.atCompactionType =
          (await AtAccessLogManagerImpl.getInstance().getAccessLog('@alice'))!
              .toString();
      await keyStore?.put(accessLogCompactionKey,
          AtData()..data = jsonEncode(atCompactionStats));

      var atData = await AccessLogCompactionStats.getInstance().getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData[AtCompactionConstants.deletedKeysCount], '431');
      expect(
          decodedData[AtCompactionConstants.postCompactionEntriesCount], '902');
      expect(
          decodedData[AtCompactionConstants.preCompactionEntriesCount], '906');
      expect(decodedData[AtCompactionConstants.compactionDurationInMills],
          '10000');
    });
  });

  group('A group of notificationCompactionStats verb tests', () {
    SecondaryKeyStoreManager? keyStoreManager;
    setUp(() async => keyStoreManager = await setUpFunc(
        '${Directory.current.path}/test/hive',
        atsign: '@alice'));

    test('notificationCompactionStats command accept test', () {
      var command = 'stats:14';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test name returned for notificationCompaction Stats', () async {
      var notificationInstance = NotificationCompactionStats.getInstance();
      String name = notificationInstance.getName();
      expect(name, 'NotificationCompactionStats');
    });

    test('notificationCompactionStats get value test', () async {
      AtCompactionStats atCompactionStats = AtCompactionStats();
      var keyStore = keyStoreManager?.getKeyStore();

      atCompactionStats.compactionDurationInMills = 10000;
      atCompactionStats.deletedKeysCount = 1;
      atCompactionStats.lastCompactionRun = DateTime.now();
      atCompactionStats.postCompactionEntriesCount = 1;
      atCompactionStats.preCompactionEntriesCount = 1;
      atCompactionStats.atCompactionType =
          AtNotificationKeystore.getInstance().toString();
      await keyStore?.put(commitLogCompactionKey,
          AtData()..data = jsonEncode(atCompactionStats));

      var atData = await CommitLogCompactionStats.getInstance().getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData[AtCompactionConstants.deletedKeysCount], '1');
      expect(
          decodedData[AtCompactionConstants.postCompactionEntriesCount], '1');
      expect(decodedData[AtCompactionConstants.preCompactionEntriesCount], '1');
      expect(decodedData[AtCompactionConstants.compactionDurationInMills],
          '10000');
    });
  });

  group('A group of test to validate latestCommitEntryOfEachKey', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to validate latestCommitEntryOfEachKey', () async {
      secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(alice);
      LastCommitIDMetricImpl.getInstance().atCommitLog =
          secondaryPersistenceStore!.getSecondaryKeyStore()!.commitLog;
      var lastCommitId =
          await LastCommitIDMetricImpl.getInstance().getMetrics();
      var randomString = Uuid().v4();
      await secondaryPersistenceStore!.getSecondaryKeyStore()!.put(
          '@alice:phone-$randomString@alice', AtData()..data = '9848033443');
      // create a new key
      await secondaryPersistenceStore!.getSecondaryKeyStore()!.put(
          '@alice:location-$randomString@alice', AtData()..data = 'Hyderabad');
      // Update the first key again
      await secondaryPersistenceStore!.getSecondaryKeyStore()!.put(
          '@alice:phone-$randomString@alice', AtData()..data = '9848033444');
      // Insert and delete a key
      await secondaryPersistenceStore!.getSecondaryKeyStore()!.put(
          '@alice:deleteKey-$randomString@alice',
          AtData()..data = '9848033444');
      await secondaryPersistenceStore!
          .getSecondaryKeyStore()!
          .remove('@alice:deleteKey-$randomString@alice');
      var latestCommitIdForEachKey =
          await LatestCommitEntryOfEachKey().getMetrics();
      var latestCommitIdMap = jsonDecode(latestCommitIdForEachKey);
      expect(latestCommitIdMap['@alice:location-$randomString@alice'][0],
          (int.parse(lastCommitId) + 2));
      expect(latestCommitIdMap['@alice:location-$randomString@alice'][1], '+');

      expect(latestCommitIdMap['@alice:phone-$randomString@alice'][0],
          (int.parse(lastCommitId) + 3));
      expect(latestCommitIdMap['@alice:phone-$randomString@alice'][1], '*');

      expect(latestCommitIdMap['@alice:deletekey-$randomString@alice'][0],
          (int.parse(lastCommitId) + 5));
      expect(latestCommitIdMap['@alice:deletekey-$randomString@alice'][1], '-');
    });
  });
}
