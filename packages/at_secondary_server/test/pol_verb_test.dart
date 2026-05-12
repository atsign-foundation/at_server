import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/pol_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() async {
  AtKeyValueStore mockKeyStore = MockAtKeyValueStore();
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
  AtCacheManager mockAtCacheManager = MockAtCacheManager();
  FakeSocket mockSocket = FakeSocket();
  EnrollmentManager mockEnrollmentManager = MockEnrollmentManager();
  NotificationManager mockNotificationManager = MockNotificationManager();

  verbTestsSetUpLogging();

  setUpAll(() {});

  test('test pol Verb', () {
    var handler = PolVerbHandler(
        mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
    var verb = handler.getVerb();
    expect(verb is Pol, true);
  });

  test('test pol command accept test', () {
    var command = 'pol';
    var handler = PolVerbHandler(
        mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
    var result = handler.accept(command);
    expect(result, true);
  });

  test('test pol verb - upper case with spaces', () {
    var verb = Pol();
    var command = 'PO L';
    command = SecondaryUtil.convertCommand(command);
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((dynamic e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  test('test pol verb - invalid syntax', () {
    var command = 'poll';
    var inbound = InboundConnectionImpl(mockSocket, null);
    var defaultVerbExecutor = DefaultVerbExecutor();
    AtSecondaryServerImpl.getInstance().currentAtSign = alice;
    var defaultVerbHandlerManager = DefaultVerbHandlerManager(
      mockKeyStore,
      mockOutboundClientManager,
      mockAtCacheManager,
      MockStatsNotificationService(),
      mockNotificationManager,
      mockEnrollmentManager,
      alice,
    );

    expect(
        () => defaultVerbExecutor.execute(
            command, inbound, defaultVerbHandlerManager),
        throwsA(predicate((dynamic e) =>
            e is InvalidSyntaxException && e.message == 'invalid command')));
  });
}
