import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
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

import 'test_utils.dart';

void main() {
  AtKeyValueStore<String, AtData, AtMetaData?> mockKeyStore =
      MockAtKeyValueStore();
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
  AtCacheManager mockAtCacheManager = MockAtCacheManager();
  FakeSocket mockSocket = FakeSocket();
  EnrollmentManager mockEnrollmentManager = MockEnrollmentManager();
  NotificationManager mockNotificationManager = MockNotificationManager();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final atServer = AtSecondaryServerImpl.getInstance();

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group('A group of stats verb tests', () {
    AtSecondaryServerImpl.getInstance().currentAtSign = alice;
    test('test stats getVerb', () {
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
      var verb = handler.getVerb();
      expect(verb is Stats, true);
    });

    test('test stats command accept test', () {
      var command = 'stats:1';
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
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
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
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
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
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
      var inbound = InboundConnectionImpl(mockSocket, null);
      var defaultVerbExecutor = DefaultVerbExecutor();
      var defaultVerbHandlerManager = DefaultVerbHandlerManager(
          mockKeyStore,
          mockOutboundClientManager,
          mockAtCacheManager,
          statsNotificationService,
          mockNotificationManager,
          mockEnrollmentManager,
          alice,
          commitLog: atCommitLog,
          accessLog: atAccessLog,
          context: verbHandlerContext);

      expect(
          () => defaultVerbExecutor.execute(
              command, inbound, defaultVerbHandlerManager),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });
  });
  group('A group of notificationStats verb tests', () {
    // test for Notification Stats
    test('notification stats command accept test', () {
      var command = 'stats:11';
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('the name of the notificationStats', () async {
      var metric = NotificationsMetricImpl(atServer.notificationManager);
      String name = metric.getName();
      expect(name, 'NotificationCount');
    });

    test('the value of the notificationStats', () async {
      Map<String, dynamic> metricsMap = <String, dynamic>{
        'total': 0,
        'type': <String, int>{
          'sent': 0,
          'received': 0,
          'self': 0,
        },
        'status': <String, int>{
          'delivered': 0,
          'failed': 0,
          'errored': 0,
          'queued': 0,
          'expired': 0,
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
          keyValueStore, verbHandlerContext, notificationManager);
      var testNotification = (AtNotificationBuilder()
            ..id = '1031'
            ..fromAtSign = '@bob'
            ..notificationDateTime =
                DateTime.now().subtract(const Duration(days: 1))
            ..toAtSign = alice
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
            ..toAtSign = alice
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
            ..toAtSign = alice
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
            ..toAtSign = alice
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
        ..fromAtSign = '@bob'.toAtsign()
        ..isAuthenticated = true;
      await notifStore.put('1031', testNotification);
      await notifStore.put('1032', testNotification2);
      await notifStore.put('1033', testNotification3);
      await notifStore.put('1034', testNotification4);
      var verb = Notify();
      var command = 'notify:update:ttr:-1:$alice:city@bob:vijayawada';
      var command2 = 'notify:delete:ttr:-1:$alice:city@bob:vijayawada';
      var command3 = 'notify:update:ttr:-1:$alice:city@bob:vijayawada';
      var command4 = 'notify:update:ttr:-1:$alice:city@bob:vijayawada';
      command = SecondaryUtil.convertCommand(command);
      command2 = SecondaryUtil.convertCommand(command2);
      command3 = SecondaryUtil.convertCommand(command3);
      command4 = SecondaryUtil.convertCommand(command4);
      var regex = verb.syntax();
      var verbParams = getVerbParam(regex, command);
      var verbParams2 = getVerbParam(regex, command2);
      var verbParams3 = getVerbParam(regex, command3);
      var verbParams4 = getVerbParam(regex, command4);
      var atConnection = InboundConnectionImpl(mockSocket, '12345')
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
      metricsMap = await NotificationsMetricImpl(atServer.notificationManager)
          .getNotificationStats(metricsMap);
      expect(metricsMap['total'], 4);
      expect(metricsMap['type']['sent'], 2);
      expect(metricsMap['type']['received'], 2);
      expect(metricsMap['status']['delivered'], 1);
      expect(metricsMap['status']['failed'], 1);
      expect(metricsMap['status']['errored'], 1);
      expect(metricsMap['status']['queued'], 2);
      expect(metricsMap['operations']['update'], 3);
      expect(metricsMap['operations']['delete'], 1);
      expect(metricsMap['messageType']['key'], 3);
      expect(metricsMap['messageType']['text'], 1);
      expect(metricsMap['createdOn'] is int, true);
    });
  });

  group('A group of commitLogCompactionStats verb tests', () {
    test('commitLogCompactionStats command accept test', () {
      var command = 'stats:12';
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test name returned for commitLogCompaction Stats', () async {
      var commitLogInstance = CommitLogCompactionStats(atServer.keyValueStore);
      String name = commitLogInstance.getName();
      expect(name, 'CommitLogCompactionStats');
    });

    test('commit Log stats get value test', () async {
      final payload = <String, String>{
        'atCompactionType': 'commitLog',
        'lastCompactionRun': DateTime.now().toUtc().toString(),
        'compactionDurationInMills': '1000',
        'deletedKeysCount': '41',
      };
      await keyValueStore.put(AtConstants.commitLogCompactionKey,
          AtData()..data = jsonEncode(payload));

      var atData =
          await CommitLogCompactionStats(atServer.keyValueStore).getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData['deletedKeysCount'].toString(), '41');
      expect(decodedData['compactionDurationInMills'].toString(), '1000');
    });
  });

  group('A group of accessLogCompactionStats verb tests', () {
    test('accessLogCompactionStats command acceptance test', () {
      var command = 'stats:13';
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('name returned for accessLogCompaction Stats test', () async {
      var accessLogInstance = AccessLogCompactionStats(atServer.keyValueStore);
      String name = accessLogInstance.getName();
      expect(name, 'AccessLogCompactionStats');
    });

    test('accessLogCompactionStats getValue test', () async {
      final payload = <String, String>{
        'atCompactionType': 'accessLog',
        'lastCompactionRun': DateTime.now().toUtc().toString(),
        'compactionDurationInMills': '10000',
        'deletedKeysCount': '431',
      };
      await keyValueStore.put(AtConstants.accessLogCompactionKey,
          AtData()..data = jsonEncode(payload));

      var atData =
          await AccessLogCompactionStats(atServer.keyValueStore).getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData['deletedKeysCount'], '431');
      expect(decodedData['compactionDurationInMills'], '10000');
    });
  });

  group('A group of notificationCompactionStats verb tests', () {
    test('notificationCompactionStats command accept test', () {
      var command = 'stats:14';
      var handler = StatsVerbHandler(mockKeyStore, verbHandlerContext,
          mockOutboundClientManager, mockNotificationManager,
          commitLog: atCommitLog, accessLog: atAccessLog);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test name returned for notificationCompaction Stats', () async {
      var notificationInstance =
          NotificationCompactionStats(atServer.keyValueStore);
      String name = notificationInstance.getName();
      expect(name, 'NotificationCompactionStats');
    });

    test('notificationCompactionStats get value test', () async {
      final payload = <String, String>{
        'atCompactionType': 'notificationKeystore',
        'lastCompactionRun': DateTime.now().toUtc().toString(),
        'compactionDurationInMills': '10000',
        'deletedKeysCount': '1',
      };
      await keyValueStore.put(AtConstants.commitLogCompactionKey,
          AtData()..data = jsonEncode(payload));

      var atData =
          await CommitLogCompactionStats(atServer.keyValueStore).getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData['deletedKeysCount'], '1');
      expect(decodedData['compactionDurationInMills'], '10000');
    });
  });

  group('A group of test to validate latestCommitEntryOfEachKey', () {
    test('A test to validate latestCommitEntryOfEachKey', () async {
      var lastCommitId =
          await LastCommitIDMetricImpl(atServer.commitLog).getMetrics();
      var randomString = Uuid().v4();
      await keyValueStore.put(
          '$alice:phone-$randomString$alice', AtData()..data = '9848033443');
      // create a new key
      await keyValueStore.put(
          '$alice:location-$randomString$alice', AtData()..data = 'Hyderabad');
      // Update the first key again
      await keyValueStore.put(
          '$alice:phone-$randomString$alice', AtData()..data = '9848033444');
      // Insert and delete a key
      await keyValueStore.put('$alice:deleteKey-$randomString$alice',
          AtData()..data = '9848033444');
      await keyValueStore.remove('$alice:deleteKey-$randomString$alice');
      var latestCommitIdForEachKey =
          await LatestCommitEntryOfEachKey(atServer.commitLog).getMetrics();
      var latestCommitIdMap = jsonDecode(latestCommitIdForEachKey);
      expect(latestCommitIdMap['$alice:location-$randomString$alice'][0],
          (int.parse(lastCommitId) + 2));
      expect(latestCommitIdMap['$alice:location-$randomString$alice'][1], '+');

      expect(latestCommitIdMap['$alice:phone-$randomString$alice'][0],
          (int.parse(lastCommitId) + 3));
      expect(latestCommitIdMap['$alice:phone-$randomString$alice'][1], '*');

      expect(latestCommitIdMap['$alice:deletekey-$randomString$alice'][0],
          (int.parse(lastCommitId) + 5));
      expect(latestCommitIdMap['$alice:deletekey-$randomString$alice'][1], '-');
    });

    test(
        'A test to validate commit entries when commit log entry count is greater than default sync buffer zie',
        () async {
      await LastCommitIDMetricImpl(atServer.commitLog).getMetrics();
      var randomString = Uuid().v4();
      int phoneNumber = 1234;
      int min = 5;
      int max = 100;
      // generate a random integer between 5 and 100
      int randomNumber = min + Random().nextInt(max - min) + 1;
      for (int i = 1; i <= randomNumber; i++) {
        phoneNumber = phoneNumber + i;
        await keyValueStore.put('$alice:phone-${randomString}_$i$alice',
            AtData()..data = phoneNumber.toString());
      }
      await LastCommitIDMetricImpl(atServer.commitLog).getMetrics();
      var latestCommitIdForEachKey =
          await LatestCommitEntryOfEachKey(atServer.commitLog).getMetrics();
      Map<String, dynamic> latestCommitIdMap =
          jsonDecode(latestCommitIdForEachKey);
      for (int i = 1; i <= randomNumber; i++) {
        expect(
            latestCommitIdMap
                .containsKey('$alice:phone-${randomString}_$i$alice'),
            true);
      }
    });

    test(
        'A test to verify latest commitId among enrolled namespaces is returned',
        () async {
      await keyValueStore.put(
          '$alice:phone.wavi$alice', AtData()..data = '9848033443');
      await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = 'Hyderabad');
      await keyValueStore.put(
          '$alice:mobile.buzz$alice', AtData()..data = '9848033444');

      var lastCommitId = await LastCommitIDMetricImpl(atServer.commitLog)
          .getMetrics(enrolledNamespaces: ['wavi']);
      expect(lastCommitId, '1');
    });

    test(
        'A test to verify highest commitId among the authorized namespaces is returned',
        () async {
      await keyValueStore.put(
          '$alice:phone.wavi$alice', AtData()..data = '9848033443');
      await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = 'Hyderabad');
      await keyValueStore.put(
          '$alice:mobile.buzz$alice', AtData()..data = '9848033444');
      await keyValueStore.put(
          '$alice:contact.atmosphere$alice', AtData()..data = '9848033444');

      var lastCommitId = await LastCommitIDMetricImpl(atServer.commitLog)
          .getMetrics(enrolledNamespaces: ['wavi', 'buzz']);
      expect(lastCommitId, '2');
    });

    test(
        'A test to verify latestCommitId is returned when enrolledNamespace and regex are not supplied',
        () async {
      await keyValueStore.put(
          '$alice:phone.wavi$alice', AtData()..data = '9848033443');
      await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = 'Hyderabad');
      await keyValueStore.put(
          '$alice:mobile.buzz$alice', AtData()..data = '9848033444');
      await keyValueStore.put(
          '$alice:contact.atmosphere$alice', AtData()..data = '9848033444');

      var lastCommitId =
          await LastCommitIDMetricImpl(atServer.commitLog).getMetrics();
      expect(lastCommitId, '3');
    });

    test(
        'A test to verify latestCommitId is returned when only regex is not supplied',
        () async {
      await keyValueStore.put(
          '$alice:phone.wavi$alice', AtData()..data = '9848033443');
      await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = 'Hyderabad');
      await keyValueStore.put(
          '$alice:mobile.buzz$alice', AtData()..data = '9848033444');
      await keyValueStore.put(
          '$alice:contact.atmosphere$alice', AtData()..data = '9848033444');

      var lastCommitId = await LastCommitIDMetricImpl(atServer.commitLog)
          .getMetrics(regex: 'buzz');
      expect(lastCommitId, '2');
    });
    test('A test to check LatestCommitEntryOfEachKey for empty commit log',
        () async {
      var latestCommitIdForEachKey =
          await LatestCommitEntryOfEachKey(atServer.commitLog).getMetrics();
      Map<String, dynamic> latestCommitIdMap =
          jsonDecode(latestCommitIdForEachKey);
      expect(latestCommitIdMap.isEmpty, true);
    });
  });

  group('StatsVerbHandler getProvider dependency-injection wiring', () {
    // Each metric must be built with exactly the collaborator it needs.
    // Construct the handler with distinguishable instances and assert which
    // one each MetricProvider receives.
    StatsVerbHandler wiringHandler() => StatsVerbHandler(mockKeyStore,
        verbHandlerContext, mockOutboundClientManager, mockNotificationManager,
        commitLog: atCommitLog, accessLog: atAccessLog);

    test('inbound metrics receive the server inbound connection pool', () {
      var handler = wiringHandler();
      final pool = atServer.inboundConnectionManager.pool;
      expect((handler.getProvider(Metric.INBOUND) as InboundMetricImpl).pool,
          same(pool));
      expect(
          (handler.getProvider(Metric.INBOUND_SUMMARY)
                  as InboundSummaryMetricImpl)
              .pool,
          same(pool));
      expect(
          (handler.getProvider(Metric.INBOUND_DETAILED)
                  as InboundDetailedMetricImpl)
              .pool,
          same(pool));
    });

    test('outbound metric receives the injected outboundClientManager', () {
      var handler = wiringHandler();
      expect(
          (handler.getProvider(Metric.OUTBOUND) as OutBoundMetricImpl)
              .outboundClientManager,
          same(mockOutboundClientManager));
    });

    test('commit-log metrics receive the injected commitLog', () {
      var handler = wiringHandler();
      expect(
          (handler.getProvider(Metric.LASTCOMMIT) as LastCommitIDMetricImpl)
              .commitLog,
          same(atCommitLog));
      expect(
          (handler.getProvider(Metric.LATEST_COMMIT_ENTRY_OF_EACH_KEY)
                  as LatestCommitEntryOfEachKey)
              .commitLog,
          same(atCommitLog));
    });

    test('access-log metrics receive the injected accessLog', () {
      var handler = wiringHandler();
      expect(
          (handler.getProvider(Metric.MOST_VISITED_ATSIGN)
                  as MostVisitedAtSignMetricImpl)
              .accessLog,
          same(atAccessLog));
      expect(
          (handler.getProvider(Metric.MOST_VISITED_ATKEYS)
                  as MostVisitedAtKeyMetricImpl)
              .accessLog,
          same(atAccessLog));
      expect(
          (handler.getProvider(Metric.LAST_LOGGEDIN_DATETIME)
                  as LastLoggedInDatetimeMetricImpl)
              .accessLog,
          same(atAccessLog));
      expect(
          (handler.getProvider(Metric.LAST_AUTH_TIME) as LastPkamMetricImpl)
              .accessLog,
          same(atAccessLog));
    });

    test('compaction metrics receive the handler keyStore', () {
      var handler = wiringHandler();
      expect(
          (handler.getProvider(Metric.COMMIT_LOG_COMPACTION)
                  as CommitLogCompactionStats)
              .keyValueStore,
          same(mockKeyStore));
      expect(
          (handler.getProvider(Metric.ACCESS_lOG_COMPACTION)
                  as AccessLogCompactionStats)
              .keyValueStore,
          same(mockKeyStore));
      expect(
          (handler.getProvider(Metric.NOTIFICATION_COMPACTION)
                  as NotificationCompactionStats)
              .keyValueStore,
          same(mockKeyStore));
    });

    test('notification metric receives the injected notificationManager', () {
      var handler = wiringHandler();
      expect(
          (handler.getProvider(Metric.NOTIFICATION_COUNT)
                  as NotificationsMetricImpl)
              .notificationManager,
          same(mockNotificationManager));
    });

    test('config-backed metrics take no collaborator', () {
      var handler = wiringHandler();
      expect(handler.getProvider(Metric.SECONDARY_STORAGE_SIZE),
          isA<SecondaryStorageMetricImpl>());
      expect(handler.getProvider(Metric.DISK_SIZE), isA<DiskSizeMetricImpl>());
      expect(handler.getProvider(Metric.SECONDARY_SERVER_VERSION),
          isA<SecondaryServerVersion>());
    });
  });

  group('StatsVerbHandler processVerb and helpers', () {
    // Build with the real collaborators so processVerb exercises the full path.
    StatsVerbHandler buildHandler() => StatsVerbHandler(keyValueStore,
        verbHandlerContext, mockOutboundClientManager, notificationManager,
        commitLog: atCommitLog, accessLog: atAccessLog);

    HashMap<String, String?> verbParams(String? statId, {String? regex}) =>
        HashMap<String, String?>.from(
            {AtConstants.statId: statId, AtConstants.regex: regex});

    List<Map> decodeStats(Response response) =>
        (jsonDecode(response.data!) as List).cast<Map>();

    test('processVerb stats:1 reports inbound connections via the late pool',
        () async {
      var handler = buildHandler();
      var response = Response();
      var connection = InboundConnectionImpl(mockSocket, null);

      await handler.processVerb(response, verbParams(':1'), connection);

      var stats = decodeStats(response);
      expect(stats.length, 1);
      expect(stats.first['name'], 'activeInboundConnections');
      // Fresh, empty inbound pool from verbTestsSetUp.
      expect(stats.first['value'], '0');
    });

    test('processVerb stats:3 returns lastCommitID via the injected commitLog',
        () async {
      await keyValueStore.put(
          '$alice:phone$alice', AtData()..data = '9848033443');
      var handler = buildHandler();
      var response = Response();
      var connection = InboundConnectionImpl(mockSocket, null);

      await handler.processVerb(response, verbParams(':3'), connection);

      var stats = decodeStats(response);
      expect(stats.length, 1);
      expect(stats.first['name'], 'lastCommitID');
      expect(stats.first['value'],
          atCommitLog.lastCommittedSequenceNumber().toString());
    });

    test('processVerb with multiple ids returns one entry per id', () async {
      var handler = buildHandler();
      var response = Response();
      var connection = InboundConnectionImpl(mockSocket, null);

      await handler.processVerb(response, verbParams(':1,7'), connection);

      var stats = decodeStats(response);
      expect(stats.length, 2);
      expect(stats.map((s) => s['name']).toSet(),
          {'activeInboundConnections', 'secondaryServerVersion'});
    });

    test('metricById maps known ids and rejects unknown ones', () {
      var handler = buildHandler();
      expect(handler.metricById('1'), Metric.INBOUND);
      expect(handler.metricById('17'), Metric.INBOUND_DETAILED);
      expect(
          () => handler.metricById('999'),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'No metric with ID 999')));
    });

    test('getStatsIDSet parses comma-separated ids and de-duplicates', () {
      var handler = buildHandler();
      expect(handler.getStatsIDSet(':1,2,2,3'), {'1', '2', '3'});
    });
  });
}
