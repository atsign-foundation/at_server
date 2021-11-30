import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
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

import 'notify_verb_test.dart';

void main() {
  group('A group of stats verb tests', () {
    test('test stats getVerb', () {
      var handler = StatsVerbHandler(null);
      var verb = handler.getVerb();
      expect(verb is Stats, true);
    });

    test('test stats command accept test', () {
      var command = 'stats:1';
      var handler = StatsVerbHandler(null);
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
      var handler = StatsVerbHandler(null);
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
      var handler = StatsVerbHandler(null);
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
      var defaultVerbHandlerManager = DefaultVerbHandlerManager();
      defaultVerbHandlerManager.init();
      expect(
          () => defaultVerbExecutor.execute(
              command, inbound, defaultVerbHandlerManager),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });
  });
  group('A group of notificationStats verb tests', () {
    SecondaryKeyStoreManager? keyStoreManager;
    setUp(() async => keyStoreManager = await setUpFunc(
        Directory.current.path + '/test/hive',
        atsign: '@alice'));
    // test for notificationstats
    test('notificationstats command accept test', () {
      var command = 'stats:11';
      var handler = StatsVerbHandler(null);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('the name of the notificationStats', () async {
      var notficationImpl = NotificationsMetricImpl.getInstance();
      String name = notficationImpl.getName();
      expect(name, 'NotificationCount');
    });

    test('the value of the notificationStats', () async {
      Map<String, dynamic> _metricsMap = <String, dynamic>{
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
      var notifyListVerbHandler =
          NotifyListVerbHandler(keyStoreManager!.getKeyStore());
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
      _metricsMap = await NotificationsMetricImpl.getInstance()
          .getNotificationStats(_metricsMap);
      expect(_metricsMap['total'], 4);
      expect(_metricsMap['type']['sent'], 2);
      expect(_metricsMap['type']['received'], 2);
      expect(_metricsMap['status']['delivered'], 1);
      expect(_metricsMap['status']['failed'], 1);
      expect(_metricsMap['status']['queued'], 2);
      expect(_metricsMap['operations']['update'], 3);
      expect(_metricsMap['operations']['delete'], 1);
      expect(_metricsMap['messageType']['key'], 3);
      expect(_metricsMap['messageType']['text'], 1);
      expect(_metricsMap['createdOn'] is int, true);
    });
    tearDown(() async => await tearDownFunc());
  });
}
