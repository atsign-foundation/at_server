import 'dart:async';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/compaction/at_compaction_stats_service_impl.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_commons/at_commons.dart';

import 'test_utils.dart';

void main() {
  AtKeyValueStore<String, AtData, AtMetaData?> mockKeyStore =
      MockAtKeyValueStore();

  group('a group of config verb regex test', () {
    test('test config add operation', () {
      var verb = Config();
      var command = 'config:block:add:$alice @bob';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], '$alice @bob');
      expect(paramsMap[AtConstants.operation], 'add');
    });

    test('test config remove operation', () {
      var verb = Config();
      var command = 'config:block:remove:$alice';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], alice);
      expect(paramsMap[AtConstants.operation], 'remove');
    });

    test('test config show operation', () {
      var verb = Config();
      var command = 'config:block:show';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], isNull);
      expect(paramsMap[AtConstants.operation], 'show');
    });

    test('test config with wrong show syntax', () {
      var verb = Config();
      var command = 'config:show:block';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test config with wrong add syntax', () {
      var verb = Config();
      var command = 'config:block:add';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('config verb with upper case', () {
      var verb = Config();
      var command = 'CONFIG:block:add:$alice @bob';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atSign], '$alice @bob');
      expect(paramsMap[AtConstants.operation], 'add');
    });
  });

  test('config verb with emoji', () {
    var verb = Config();
    var command = 'config:block:add:@🦄 @🐫🐫';
    var regex = verb.syntax();
    var paramsMap = getVerbParam(regex, command);
    expect(paramsMap[AtConstants.atSign], '@🦄 @🐫🐫');
    expect(paramsMap[AtConstants.operation], 'add');
  });

  test('config verb with emoji with invalid syntax', () {
    var verb = Config();
    var command = 'config:block:@🦄 @🐫🐫';
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((dynamic e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  test('config verb with emoji and no @', () {
    var verb = Config();
    var command = 'config:block:add:🦄 🐫🐫';
    var regex = verb.syntax();
    expect(
        () => getVerbParam(regex, command),
        throwsA(predicate((dynamic e) =>
            e is InvalidSyntaxException && e.message == 'Syntax Exception')));
  });

  group('A group of config verb handler test', () {
    test('test config verb handler - add config', () {
      var command = 'config:block:add:$alice @bob';
      AbstractVerbHandler verbHandler =
          ConfigVerbHandler(mockKeyStore, commitLog: atCommitLog);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AtConstants.atSign], '$alice @bob');
      expect(verbParameters[AtConstants.operation], 'add');
    });

    test('test config verb handler - remove config', () {
      var command = 'config:block:remove:$alice @bob';
      AbstractVerbHandler verbHandler =
          ConfigVerbHandler(mockKeyStore, commitLog: atCommitLog);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AtConstants.atSign], '$alice @bob');
      expect(verbParameters[AtConstants.operation], 'remove');
    });

    test('test config verb handler - show config', () {
      var command = 'config:block:show';
      AbstractVerbHandler verbHandler =
          ConfigVerbHandler(mockKeyStore, commitLog: atCommitLog);
      var verbParameters = verbHandler.parse(command);
      var verb = verbHandler.getVerb();
      expect(verb is Config, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AtConstants.atSign], isNull);
      expect(verbParameters[AtConstants.operation], 'show');
    });

    test('test config key- invalid add command', () {
      var command = 'config:block:add';
      AbstractVerbHandler handler =
          ConfigVerbHandler(mockKeyStore, commitLog: atCommitLog);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });

    test('test config key- invalid remove command', () {
      var command = 'config:block:remove:';
      AbstractVerbHandler handler =
          ConfigVerbHandler(mockKeyStore, commitLog: atCommitLog);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });

    test('test config key- invalid show command', () {
      var command = 'config:block:show:$alice';
      AbstractVerbHandler handler =
          ConfigVerbHandler(mockKeyStore, commitLog: atCommitLog);
      expect(
          () => handler.parse(command), throwsA(isA<InvalidSyntaxException>()));
    });
  });

  group('config:set', () {
    /// Every error that escaped to the zone the atServer's own config
    /// listeners were registered in.
    late List<Object> uncaught;

    setUpAll(() async => await verbTestsSetUpAll());
    setUp(() async {
      await verbTestsSetUp();
      final AtSecondaryServerImpl server = AtSecondaryServerImpl.getInstance();
      server.inboundConnectionManager =
          InboundConnectionManager(serverAtSign: alice, poolSize: 5);
      uncaught = [];
      await runZonedGuarded(
          () async => await server.initDynamicConfigListeners(),
          (e, _) => uncaught.add(e));
    });
    tearDown(() async => await verbTestsTearDown());

    /// Sends `config:set:<setting>` on a CRAM connection and returns what
    /// the handler threw with what escaped to the listeners' zone so far.
    Future<(Object?, List<Object>)> set(String setting) async {
      final connection = DummyInboundConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.cram;
      Object? thrown;
      try {
        await ConfigVerbHandler(keyValueStore, commitLog: atCommitLog)
            .process('config:set:$setting', connection);
      } catch (e) {
        thrown = e;
      }
      await Future.delayed(const Duration(milliseconds: 100));
      return (thrown, uncaught);
    }

    for (final (config, value, takes) in [
      (ModifiableConfigs.inboundMaxLimit, 'abc', 'a positive integer'),
      (ModifiableConfigs.inboundMaxLimit, '0', 'a positive integer'),
      (
        ModifiableConfigs.commitLogCompactionFrequencyMins,
        '1.5',
        'a positive integer'
      ),
      (
        ModifiableConfigs.accessLogCompactionFrequencyMins,
        '0',
        'a positive integer'
      ),
      (
        ModifiableConfigs.notificationKeyStoreCompactionFrequencyMins,
        '-5',
        'a positive integer'
      ),
      (ModifiableConfigs.maxRequestsPerTimeFrame, '', 'a positive integer'),
      (ModifiableConfigs.maxRequestsPerTimeFrame, '-1', 'a positive integer'),
      (ModifiableConfigs.timeFrameInMillis, '0', 'a positive integer'),
      (ModifiableConfigs.autoNotify, 'yes', 'true or false'),
    ]) {
      test('refuses ${config.name}=$value, and no listener sees it', () async {
        final Object? before = AtSecondaryConfig.getLatestConfigValue(config);
        final (thrown, uncaught) = await set('${config.name}=$value');
        expect(
            thrown,
            isA<InvalidSyntaxException>().having(
                (e) => e.message, 'message', '${config.name} takes $takes'));
        expect(uncaught, isEmpty);
        expect(AtSecondaryConfig.getLatestConfigValue(config), before);
      });
    }

    test('changing one compaction frequency leaves the others scheduled',
        () async {
      final AtSecondaryServerImpl server = AtSecondaryServerImpl.getInstance();
      addTearDown(() {
        for (final t in server.compactionTimers.values) {
          t.cancel();
        }
      });
      for (final setting in [
        'commitLogCompactionFrequencyMins=5',
        'accessLogCompactionFrequencyMins=7',
      ]) {
        final (thrown, uncaught) = await set(setting);
        expect(thrown, isNull, reason: setting);
        expect(uncaught, isEmpty, reason: setting);
      }
      expect(server.compactionTimers.keys,
          containsAll(['commitLog', 'accessLog']));
      expect(server.compactionTimers.values.every((t) => t.isActive), isTrue,
          reason: 'the second change must not cancel the first resource\'s '
              'timer');
    });

    test('a compaction still running when its timer is replaced is not '
        'overlapped', () async {
      final AtSecondaryServerImpl server = AtSecondaryServerImpl.getInstance();
      final _BlockingCompactable resource = _BlockingCompactable();
      final AtCompactionStatsService stats =
          AtCompactionStatsService(keyValueStore);
      addTearDown(() {
        resource.release();
        server.compactionTimers['blocking']?.cancel();
      });
      const Duration period = Duration(milliseconds: 10);

      server.scheduleCompaction(resource, period, 'blocking', stats);
      await resource.firstStarted.future;
      server.scheduleCompaction(resource, period, 'blocking', stats);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(resource.passes, 1,
          reason: 'the new timer must not start a pass while the old '
              'timer\'s pass is still running');
      resource.release();
      await Future.delayed(const Duration(milliseconds: 100));
      expect(resource.passes, greaterThan(1),
          reason: 'once that pass ends, the new timer compacts again');
    });

    test('control: values a config can take are applied', () async {
      for (final setting in ['inboundMaxLimit=7', 'autoNotify=false']) {
        final (thrown, uncaught) = await set(setting);
        expect(thrown, isNull, reason: setting);
        expect(uncaught, isEmpty, reason: setting);
      }
      expect(
          AtSecondaryServerImpl.getInstance()
              .inboundConnectionManager
              .pool
              .getCapacity(),
          7);
      expect(
          AtSecondaryConfig.getLatestConfigValue(ModifiableConfigs.autoNotify)
              .toString(),
          'false');
    });
  });
}

/// A resource whose every compaction pass waits until [release] is called.
class _BlockingCompactable implements Compactable {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> _released = Completer<void>();
  int passes = 0;

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  Stream<Object> compact(bool dryRun) async* {
    passes++;
    if (!firstStarted.isCompleted) firstStarted.complete();
    await _released.future;
  }
}
