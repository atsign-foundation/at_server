import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The scenarios of refusals.feature that a sending atServer proves, each
/// under its title.
void main() {
  final Atsign chuck = '@chuck'.toAtsign();

  setUpAll(() {
    registerFallbackValue(AtNotificationBuilder().build());
  });

  late NotificationManager manager;
  late MockOutboundClient client;
  late Map<String, Completer<AtNotification>> stored;

  setUp(() {
    manager = NotificationManager(
        chuck, MockAtNotificationKeystore(), MockNotifyConnectionsPool());
    stored = {};
    when(() => manager.notifStore.put(any(), any(),
        skipCommit: any(named: 'skipCommit'))).thenAnswer((invocation) async {
      final AtNotification n = invocation.positionalArguments[1];
      if (n.notificationStatus != NotificationStatus.queued) {
        stored.putIfAbsent(n.id!, () => Completer()).complete(n);
      }
      return null;
    });
    client = MockOutboundClient();
    when(() => manager.notifyConnectionsPool
            .getOutboundClient(any(), connect: true))
        .thenAnswer((_) async => client);
  });

  AtNotification queued(String id) => (AtNotificationBuilder()
        ..id = id
        ..type = NotificationType.sent
        ..toAtSign = alice
        ..fromAtSign = '$chuck'
        ..notification = '$alice:$id.invitations.chat$chuck')
      .build();

  Future<AtNotification> settled(String id) =>
      stored.putIfAbsent(id, () => Completer()).future;

  /// Makes a notification the gate lets through settle as delivered, so a
  /// check that fails shows as its status rather than as a timeout.
  void deliveredIfSent() =>
      when(() => client.notify(any(), handshake: any(named: 'handshake')))
          .thenAnswer((_) async => 'data:success');

  test('A sending atServer discards a refused notification at once',
      () async {
    when(() => client.notify(any(), handshake: true))
        .thenThrow(QuarantineLimitException('limit'));
    manager.enqueue(queued('11'));
    expect((await settled('11')).notificationStatus,
        NotificationStatus.refused);
    await Future.delayed(PerAtSignNotifSender.initialDelay * 2);
    verify(() => client.notify(any(), handshake: true)).called(1);
  });

  test('A refusal does not hold back the next notification', () async {
    when(() => client.notify(any(that: contains('11.invitations')),
            handshake: true))
        .thenThrow(QuarantineLimitException('limit'));
    when(() => client.notify(any(that: contains('12.invitations')),
        handshake: true)).thenAnswer((_) async => 'data:success');
    final Stopwatch clock = Stopwatch()..start();
    manager.enqueue(queued('11'));
    manager.enqueue(queued('12'));
    expect((await settled('12')).notificationStatus,
        NotificationStatus.delivered);
    expect(clock.elapsed, lessThan(PerAtSignNotifSender.initialDelay));
    expect((await settled('11')).notificationStatus,
        NotificationStatus.refused);
  });

  test('A queued notification is checked again at delivery', () async {
    manager = NotificationManager(
        alice, manager.notifStore, manager.notifyConnectionsPool);
    final Gatekeeper alicesGate = Gatekeeper(defaultMode: GateDefault.closed);
    await alicesGate.setRule('chat', GateMode.closed, admit: bob.toAtsign());
    manager.gatekeeper = alicesGate;
    await alicesGate.remove('chat', bob.toAtsign());
    deliveredIfSent();
    manager.enqueue((AtNotificationBuilder()
          ..id = '21'
          ..type = NotificationType.sent
          ..toAtSign = bob
          ..fromAtSign = alice
          ..notification = '$bob:msg.chat$alice')
        .build());
    expect((await settled('21')).notificationStatus,
        NotificationStatus.refused);
    verifyNever(
        () => client.notify(any(), handshake: any(named: 'handshake')));
  });

  test(
      'A notification queued before its recipient was blocklisted is never'
      ' delivered', () async {
    manager = NotificationManager(
        alice, manager.notifStore, manager.notifyConnectionsPool);
    final Gatekeeper alicesGate = Gatekeeper(defaultMode: GateDefault.closed);
    await alicesGate.setRule('chat', GateMode.closed, admit: bob.toAtsign());
    await alicesGate.admit('chat', chuck);
    manager.gatekeeper = alicesGate;
    await alicesGate.blocklistChanged({chuck});
    deliveredIfSent();
    manager.enqueue((AtNotificationBuilder()
          ..id = '41'
          ..type = NotificationType.sent
          ..toAtSign = '$chuck'
          ..fromAtSign = alice
          ..notification = '$chuck:msg.chat$alice')
        .build());
    expect((await settled('41')).notificationStatus,
        NotificationStatus.refused);
    verifyNever(
        () => client.notify(any(), handshake: any(named: 'handshake')));
  });
}
