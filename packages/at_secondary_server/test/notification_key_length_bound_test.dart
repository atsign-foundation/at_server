import 'dart:async';

import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/notification_telemetry.dart';
import 'package:at_telemetry/at_telemetry.dart' show AtTelemetryLogRecord;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'telemetry_test_support.dart';
import 'test_utils.dart';

/// Catalogue: features/notify/notification_key_length_bound.feature
void main() {
  /// An atKey name that makes the full key, `<forAtSign>:<name>@alice`, as
  /// long as [length], for [forAtSign].
  String keyName(int length, {String forAtSign = '@bob'}) {
    final int k =
        length - '$forAtSign:'.length - '@alice'.length - '.wavi'.length;
    return '${'k' * k}.wavi';
  }

  setUpAll(() async {
    await verbTestsSetUpAll();
    registerFallbackValue(AtNotificationBuilder().build());
  });

  setUp(() async => await setUpAtSignBound());

  tearDown(() async => await verbTestsTearDown());

  group('Given a client authenticated as @alice', () {
    for (final (String what, String command, int length) in [
      (
        'a notify to @bob whose key has 256 characters',
        'notify:update:@bob:${keyName(256)}@alice:v',
        256
      ),
      (
        'a notify to @bob with a ttr whose key has 250 characters',
        'notify:update:ttr:100000:ccd:true:@bob:${keyName(250)}@alice:v',
        257
      ),
      (
        'a notify to its own atSign whose key has 256 characters',
        'notify:update:@alice:${keyName(256, forAtSign: '@alice')}@alice:v',
        256
      ),
      (
        'a delete notify to @bob whose key has 249 characters',
        'notify:delete:@bob:${keyName(249)}@alice',
        256
      ),
    ]) {
      test(
          'when it sends $what, then it is refused with AT0016 and nothing is stored, queued or sent',
          () async {
        final Connection client = aliceClient();
        final List<Object?> before = await footprint();

        await send(command, client);

        expect(client.writes, [
          'error:AT0016-Invalid key : notification key length $length is'
              ' greater than 255 chars\n@alice@'
        ]);
        expect(await footprint(), before);
        expect(await sentTo('@bob'), isEmpty);
        expect(client.closeCount, 0);
      });
    }

    test(
        'when it sends notify:all to @bob and an atSign whose key would be 259 characters, then it is refused with AT0016 and nothing is stored for either',
        () async {
      final Connection client = aliceClient();
      final List<Object?> before = await footprint();

      await send(
          'notify:all:@bob,@carolinecarolinecarol:${'k' * 225}.wavi@alice',
          client);

      expect(client.writes, [
        'error:AT0016-Invalid key : notification key length 259 is greater'
            ' than 255 chars\n@alice@'
      ]);
      expect(await footprint(), before);
    });

    test(
        'when it sends a notify to @bob whose key has 255 characters and no ttr, and one with a ttr whose key has 248, then both are accepted for @bob',
        () async {
      final Connection client = aliceClient();

      await send('notify:update:@bob:${keyName(255)}@alice:v', client);
      await send(
          'notify:update:ttr:100000:ccd:true:@bob:${keyName(248)}@alice:v',
          client);

      expect(client.writes, [
        matches(RegExp(r'^data:[0-9a-f-]{36}\n@alice@$')),
        matches(RegExp(r'^data:[0-9a-f-]{36}\n@alice@$')),
      ]);
      expect(await sentTo('@bob'), hasLength(2));
    });
  });

  group('Given notifications to @bob queued before this check existed', () {
    late AtServerTelemetry telemetry;
    late RecordingExporter exporter;
    late NotificationManager nm;
    late List<String> attempted;
    late List<String> severe;
    final Duration savedInitialDelay = PerAtSignNotifSender.initialDelay;

    setUp(() {
      telemetry = AtServerTelemetry(heartbeatInterval: null);
      exporter = RecordingExporter();
      enableRecording(telemetry, exporter);
      nm = NotificationManager(
          alice, MockAtNotificationKeystore(), MockNotifyConnectionsPool(),
          telemetry: NotificationTelemetry(telemetry));
      when(() => nm.notifStore.put(any(), any(),
          skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async => null);
      final MockSecondaryAddressFinder finder = MockSecondaryAddressFinder();
      when(() => finder.findSecondary(bob)).thenAnswer(
          (_) async => at_lookup.SecondaryAddress('bob.example.com', 1234));
      when(() => nm.notifyConnectionsPool.secondaryAddressFinder)
          .thenReturn(finder);
      final MockOutboundClient client = MockOutboundClient();
      when(() => nm.notifyConnectionsPool.getOutboundClient(bob))
          .thenAnswer((_) async => client);
      when(() => client.usePeerFeature(any())).thenAnswer((_) async => false);
      attempted = <String>[];
      when(() => client.notify(any())).thenAnswer((Invocation i) async {
        attempted.add(i.positionalArguments[0] as String);
        return 'data:success';
      });
      PerAtSignNotifSender.initialDelay = const Duration(milliseconds: 5);
      final PerAtSignNotifSender sender = nm.getPerAtSignNotifSender(bob);
      sender.logger.level = 'warning';
      severe = <String>[];
      final StreamSubscription<LogRecord> logs = sender.logger.logger.onRecord
          .where((LogRecord r) => r.level == Level.SEVERE)
          .listen((LogRecord r) => severe.add(r.message));
      addTearDown(logs.cancel);
    });

    tearDown(() async {
      PerAtSignNotifSender.initialDelay = savedInitialDelay;
      await nm.close();
      await telemetry.shutdown();
    });

    AtNotification queued(String id, String key, {int? ttr}) =>
        (AtNotificationBuilder()
              ..id = id
              ..type = NotificationType.sent
              ..fromAtSign = alice
              ..toAtSign = '@bob'
              ..notification = '@bob:$key@alice'
              ..atMetaData = (AtMetaData()..ttr = ttr))
            .build();

    test(
        'when the sender reaches one whose key has 256 characters, then it is not sent, it is marked errored and reported, one severe line names it, and the later ones at the limit are sent without waiting behind it',
        () async {
      final AtNotification tooLong = queued('too-long', keyName(256));
      final AtNotification atLimit = queued('at-limit', keyName(255));
      final AtNotification cachedAtLimit =
          queued('cached-at-limit', keyName(248), ttr: 100000);

      await nm.notify(tooLong);
      await nm.notify(atLimit);
      await nm.notify(cachedAtLimit);
      for (int i = 0; i < 100 && attempted.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(attempted.where((String c) => c.contains(keyName(256))), isEmpty,
          reason: 'the one too long is not sent');
      expect(attempted, hasLength(2),
          reason: 'the later ones at the limit are sent without waiting');
      expect(tooLong.notificationStatus, NotificationStatus.errored);
      expect(atLimit.notificationStatus, NotificationStatus.delivered);
      expect(cachedAtLimit.notificationStatus, NotificationStatus.delivered);
      expect(severe.single, allOf(contains('too-long'), contains('256')));
      final AtTelemetryLogRecord error = await exporter
          .firstNamed('atsign.atserver.notification.error')
          .timeout(const Duration(seconds: 2));
      expect(error.attributes['atsign.notification.ids'], ['too-long']);
    });
  });
}
