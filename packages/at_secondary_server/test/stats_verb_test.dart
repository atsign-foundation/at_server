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
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/stats_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
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
          accessLog: atAccessLog);

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
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('the name of the notificationStats', () async {
      var metric = NotificationsMetricImpl(atServer);
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
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyValueStore, notificationManager);
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
      metricsMap = await NotificationsMetricImpl(atServer)
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
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test name returned for commitLogCompaction Stats', () async {
      var commitLogInstance = CommitLogCompactionStats(atServer);
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

      var atData = await CommitLogCompactionStats(atServer).getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData['deletedKeysCount'].toString(), '41');
      expect(decodedData['compactionDurationInMills'].toString(), '1000');
    });
  });

  group('A group of accessLogCompactionStats verb tests', () {
    test('accessLogCompactionStats command acceptance test', () {
      var command = 'stats:13';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('name returned for accessLogCompaction Stats test', () async {
      var accessLogInstance = AccessLogCompactionStats(atServer);
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

      var atData = await AccessLogCompactionStats(atServer).getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData['deletedKeysCount'], '431');
      expect(decodedData['compactionDurationInMills'], '10000');
    });
  });

  group('A group of notificationCompactionStats verb tests', () {
    test('notificationCompactionStats command accept test', () {
      var command = 'stats:14';
      var handler = StatsVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test name returned for notificationCompaction Stats', () async {
      var notificationInstance = NotificationCompactionStats(atServer);
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

      var atData = await CommitLogCompactionStats(atServer).getMetrics();
      var decodedData = jsonDecode(atData!) as Map;
      expect(decodedData['deletedKeysCount'], '1');
      expect(decodedData['compactionDurationInMills'], '10000');
    });
  });

  group('A group of test to validate latestCommitEntryOfEachKey', () {
    test('A test to validate latestCommitEntryOfEachKey', () async {
      var lastCommitId = await LastCommitIDMetricImpl(atServer).getMetrics();
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
          await LatestCommitEntryOfEachKey(atServer).getMetrics();
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
      await LastCommitIDMetricImpl(atServer).getMetrics();
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
      await LastCommitIDMetricImpl(atServer).getMetrics();
      var latestCommitIdForEachKey =
          await LatestCommitEntryOfEachKey(atServer).getMetrics();
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

      var lastCommitId = await LastCommitIDMetricImpl(atServer).getMetrics();
      expect(lastCommitId, '3');
    });

    test('A test to check LatestCommitEntryOfEachKey for empty commit log',
        () async {
      var latestCommitIdForEachKey =
          await LatestCommitEntryOfEachKey(atServer).getMetrics();
      Map<String, dynamic> latestCommitIdMap =
          jsonDecode(latestCommitIdForEachKey);
      expect(latestCommitIdMap.isEmpty, true);
    });
  });

  group('stats:3 through the verb handler', () {
    /// The lastCommitID that `stats:3`, filtered by [regex] when given,
    /// answers on a CRAM connection, which has no enrollment.
    Future<String> lastCommitIdFromVerb([String? regex]) async {
      inboundConnection.metadata
        ..isAuthenticated = true
        ..authType = AuthType.cram;
      final response = await StatsVerbHandler(keyValueStore).processInternal(
          regex == null ? 'stats:3' : 'stats:3:$regex', inboundConnection);
      return (jsonDecode(response.data!) as List).single['value'];
    }

    /// Writes two keys, then rewrites the second with no commit, which
    /// purges the newest entry. Returns the id the second key was issued.
    Future<int> purgeNewest() async {
      await keyValueStore.put('$alice:phone.wavi$alice', AtData()..data = '1');
      final purgedId = (await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = '2'))!;
      await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = '3',
          skipCommit: true);
      return purgedId;
    }

    test('an unfiltered request reports the last commit id after a purge',
        () async {
      final purgedId = await purgeNewest();
      expect(await lastCommitIdFromVerb(), '$purgedId',
          reason: 'a client may already hold the purged id, and compares it '
              'with this answer');
      expect(await lastCommitIdFromVerb('.*'), '$purgedId',
          reason: 'an explicit .* admits every key, as no regex does');
    });

    test('a filtered request reports the highest id it admits', () async {
      final purgedId = await purgeNewest();
      expect(await lastCommitIdFromVerb('wavi'), '${purgedId - 1}',
          reason: 'a filtered request answers from the entries it admits');
    });

    test('an unfiltered request on an empty log reports -1', () async {
      expect(await lastCommitIdFromVerb(), '-1');
    });
  });

  group('stats:3 counts what sync:from sends', () {
    /// Enrols [connection] with [namespaces] and returns its enrollment id.
    Future<String> enrolWith(DummyInboundConnection connection,
        Map<String, String> namespaces) async {
      final String enrollmentId = Uuid().v4();
      await keyValueStore.put(
          '$enrollmentId.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': namespaces,
              'apkamPublicKey': 'testPublicKeyValue',
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'}
            }),
          skipCommit: true);
      connection.metadata
        ..isAuthenticated = true
        ..authType = AuthType.apkam
        ..enrollmentId = enrollmentId;
      return enrollmentId;
    }

    /// What `stats:3`, with [regex] when given, answers on [connection].
    Future<String> statsLastCommitId(DummyInboundConnection connection,
        {String? regex, StatsVerbHandler? handler}) async {
      final response = Response();
      await (handler ?? StatsVerbHandler(keyValueStore)).processVerb(
          response,
          HashMap.of({
            AtConstants.statId: '3',
            if (regex != null) AtConstants.regex: regex,
          }),
          connection);
      return (jsonDecode(response.data!) as List).single['value'];
    }

    /// The highest commit id `sync:from`, with [regex] when given, sends
    /// [connection], or `'null'` when it sends nothing.
    Future<String> syncedLastCommitId(DummyInboundConnection connection,
        {String? regex}) async {
      final response = Response();
      await SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog)
          .processVerb(
              response,
              HashMap.of({
                AtConstants.fromCommitSequence: '-1',
                AtConstants.syncLimit: '100',
                if (regex != null) 'regex': regex,
              }),
              connection);
      final ids = [
        for (final entry in jsonDecode(response.data!) as List)
          entry['commitId'] as int
      ];
      return ids.isEmpty ? 'null' : '${ids.reduce(max)}';
    }

    Future<void> put(String key) =>
        keyValueStore.put(key, AtData()..data = 'v');

    test('an enrollment counts its own namespace', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      await put('$alice:phone.wavi$alice');
      await put('$alice:location.wavi$alice');
      await put('$alice:mobile.buzz$alice');
      expect(await statsLastCommitId(connection), '1');
      expect(await syncedLastCommitId(connection), '1');
    });

    test('an enrollment counts every namespace it holds', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw', 'buzz': 'rw'});
      await put('$alice:phone.wavi$alice');
      await put('$alice:location.wavi$alice');
      await put('$alice:mobile.buzz$alice');
      await put('$alice:contact.atmosphere$alice');
      expect(await statsLastCommitId(connection), '2');
      expect(await syncedLastCommitId(connection), '2');
    });

    test('a CRAM connection\'s regex filters the count', () async {
      final connection = DummyInboundConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.cram;
      await put('$alice:phone.wavi$alice');
      await put('$alice:location.wavi$alice');
      await put('$alice:mobile.buzz$alice');
      await put('$alice:contact.atmosphere$alice');
      expect(await statsLastCommitId(connection, regex: 'buzz'), '2');
      expect(await syncedLastCommitId(connection, regex: 'buzz'), '2');
    });

    test('an enrollment holding * is unfiltered', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'*': 'rw', '__manage': 'rw'});
      await put('phone.wavi$alice');
      final purgedId = (await keyValueStore.put(
          'location.wavi$alice', AtData()..data = 'v'))!;
      await keyValueStore.put('location.wavi$alice', AtData()..data = 'v2',
          skipCommit: true);
      expect(await statsLastCommitId(connection), '$purgedId',
          reason: 'an enrollment holding * filters nothing, so it gets the '
              'last commit id issued, which a purge does not lower');
    });

    test('an enrollment\'s own reserved-namespace key is counted', () async {
      final connection = DummyInboundConnection();
      final enrollmentId = await enrolWith(connection, {'wavi': 'rw'});
      await put('phone.wavi$alice');
      await put('__ckcur.bob.wavi.'
          '${AbstractVerbHandler.enrollmentReservedNamespace(enrollmentId)}'
          '$alice');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'sync:from sends an enrollment its own .a.__e keys');
    });

    test('an __atserver key is counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      await put('phone.wavi$alice');
      await put('config.__atserver$alice');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'every enrollment reads the __atserver namespace');
    });

    test('a multi-segment enrolled namespace is counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'chat.wavi': 'rw'});
      await put('msg1.chat.wavi$alice');
      expect(await syncedLastCommitId(connection), isNot('null'),
          reason: 'the case this test is about did not arise');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'sync:from matches chat.wavi against the whole key');
    });

    test('a __manage key is not counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw', '__manage': 'rw'});
      await put('phone.wavi$alice');
      final manageKey = '${Uuid().v4()}.new.enrollments.__manage$alice';
      await keyValueStore.put(manageKey, AtData()..data = '{}',
          skipCommit: true);
      await atCommitLog.commit(manageKey, CommitOp.UPDATE);
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'sync:from never sends a __manage key');
    });

    test('a configkey entry neither breaks the count nor is counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      await put('phone.wavi$alice');
      await keyValueStore.put('configkey', AtData()..data = '[]');
      expect(atCommitLog.getLatestCommitEntry('configkey'), isNotNull,
          reason: 'the blocklist key must be in the commit log for this test');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'configkey is not a well-formed atKey (#1570), and sync:from '
              'skips it');
    });

    test('a regex filters the count as it filters sync:from', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'*': 'rw'});
      await put('phone.wavi$alice');
      await put('mobile.buzz$alice');
      expect(await statsLastCommitId(connection, regex: 'wavi'),
          await syncedLastCommitId(connection, regex: 'wavi'));
    });

    test('concurrent requests each answer for their own regex', () async {
      await put('phone.wavi$alice');
      await put('mobile.buzz$alice');
      final enrolled = DummyInboundConnection();
      await enrolWith(enrolled, {'*': 'rw'});
      final cram = DummyInboundConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.cram;
      final handler = StatsVerbHandler(keyValueStore);
      final answers = await Future.wait([
        statsLastCommitId(enrolled, regex: 'wavi', handler: handler),
        statsLastCommitId(cram, regex: 'buzz', handler: handler),
      ]);
      expect(
          answers,
          [
            await syncedLastCommitId(enrolled, regex: 'wavi'),
            await syncedLastCommitId(cram, regex: 'buzz'),
          ],
          reason: 'one handler serves every connection, so a request must not '
              'read another request\'s regex');
    });
  });
}
