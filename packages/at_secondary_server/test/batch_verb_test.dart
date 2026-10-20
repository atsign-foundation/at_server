import 'dart:convert';

import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Catalogue: features/authentication/cram_after_pkam.feature
void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  BatchVerbHandler batchHandler() => BatchVerbHandler(
      keyValueStore,
      DefaultVerbHandlerManager(
          keyValueStore,
          mockOutboundClientManager,
          cacheManager,
          statsNotificationService,
          notificationManager,
          enMgr,
          alice,
          commitLog: atCommitLog,
          accessLog: atAccessLog));

  /// Runs a batch of [command] alone over [inboundConnection] and returns its
  /// one entry.
  Future<Map> onlyEntry(String command) async {
    final response = await batchHandler().processInternal(
        'batch:${jsonEncode([
              {'id': 1, 'command': command}
            ])}',
        inboundConnection);
    final List entries = jsonDecode(response.data!);
    expect(entries, hasLength(1));
    return entries.single as Map;
  }

  group('Given an authenticated connection', () {
    for (final AuthType authType in [
      AuthType.cram,
      AuthType.pkamLegacy,
      AuthType.apkam
    ]) {
      for (final String command in ['cram:abc', 'pkam:abc']) {
        test(
            'when a batch runs $command, then that command is refused with '
            'AT0009 ($authType)', () async {
          inboundConnection.metadata
            ..isAuthenticated = true
            ..authType = authType;

          final Map entry = await onlyEntry(command);

          expect(entry['id'], 1);
          expect(entry['response']['error_code'], 'AT0009');
          expect(inboundConnection.metadata.isAuthenticated, isTrue);
          expect(inboundConnection.metadata.authType, authType);
        });
      }
    }

    test('when a batch runs another command, then it runs', () async {
      inboundConnection.metadata
        ..isAuthenticated = true
        ..authType = AuthType.cram;

      final Map entry = await onlyEntry('update:public:phone$alice 123');

      expect(entry['response']['error_code'], isNull);
      expect(entry['response']['data'], isNotNull);
    });

    test(
        'when a batch runs a command no verb handles, then that command is '
        'refused with AT0003', () async {
      inboundConnection.metadata
        ..isAuthenticated = true
        ..authType = AuthType.cram;

      final Map entry = await onlyEntry('nosuchverb:abc');

      expect(entry['id'], 1);
      expect(entry['response']['error_code'], 'AT0003');
    });
  });
}
