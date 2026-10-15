import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_fetch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

import '../test_utils.dart';

/// Catalogue: docs/projects/gatekeeper/features/quarantine.feature
///
/// The scenarios whose observable is what @alice's own clients, or another
/// atServer's scan and notify:list, are answered, each under its title.
void main() {
  final Atsign bob = '@bob'.toAtsign();
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();
  const String inv = 'invitations.chat';

  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    await gate().setDefault(GateDefault.closed);
    await gate().setRule(inv, GateMode.open);
  });

  tearDown(() async => await verbTestsTearDown());

  DummyInboundConnection fromAtServerOf(Atsign other) =>
      DummyInboundConnection()
        ..metadata.isPolAuthenticated = true
        ..metadata.fromAtSign = other;

  DummyInboundConnection ownClient() => DummyInboundConnection()
    ..metadata.isAuthenticated = true
    ..metadata.authType = AuthType.cram;

  /// Notification [id] from [chuck], accepted while [chuck] is quarantined.
  Future<void> heldFromQuarantined(String id) async {
    await NotifyVerbHandler(keyValueStore, notificationManager).processInternal(
        'notify:id:$id:@alice:inv$id.invitations.chat@chuck',
        fromAtServerOf(chuck));
    expect((await notificationManager.get(id))!.quarantined, isTrue);
  }

  Future<String?> clientSends(
          AbstractVerbHandler Function() handler, String command) async =>
      (await handler().processInternal(command, ownClient())).data;

  test('A scan answers only entries in namespaces where the atSign is admitted',
      () async {
    await gate().setRule('chat', GateMode.open, admit: bob);
    await gate().count(bob, 'x.$inv');
    await keyValueStore.put('@bob:status.chat$alice', AtData()..data = 's');
    await keyValueStore.put(
        '@bob:profile.invitations.chat$alice', AtData()..data = 'p');
    final String? answer = (await ScanVerbHandler(
                keyValueStore, mockOutboundClientManager, cacheManager)
            .processInternal('scan', fromAtServerOf(bob)))
        .data;
    expect(jsonDecode(answer!), ['status.chat$alice']);
    expect(gate().quarantinedIn(inv)[bob]!.counted.length, 1);
  });

  test('A scan from an atSign admitted nowhere answers an empty list',
      () async {
    await keyValueStore.put(
        '@dave:profile.invitations.chat$alice', AtData()..data = 'p');
    final String? answer = (await ScanVerbHandler(
                keyValueStore, mockOutboundClientManager, cacheManager)
            .processInternal('scan', fromAtServerOf(dave)))
        .data;
    expect(jsonDecode(answer!), isEmpty);
  });

  test(
      'notify:list answers only notifications in namespaces where the atSign'
      ' is admitted', () async {
    await gate().setRule('chat', GateMode.open, admit: bob);
    await gate().count(bob, 'x.$inv');
    for (final (String id, String key) in [
      ('s1', '@bob:msg.chat$alice'),
      ('s2', '@bob:inv.invitations.chat$alice'),
    ]) {
      await notifStore.put(
          id,
          (AtNotificationBuilder()
                ..id = id
                ..fromAtSign = '$alice'
                ..toAtSign = '$bob'
                ..notification = key
                ..type = NotificationType.sent
                ..opType = OperationType.update)
              .build());
    }
    final String? answer = (await NotifyListVerbHandler(
                keyValueStore, notificationManager)
            .processInternal('notify:list', fromAtServerOf(bob)))
        .data;
    expect([for (final n in jsonDecode(answer!)) n['id']], ['s1']);
  });

  test('A client that asks receives quarantined notifications, marked',
      () async {
    await heldFromQuarantined('21');
    final DummyInboundConnection client = ownClient();
    final MonitorVerbHandler monitor =
        MonitorVerbHandler(keyValueStore, notificationManager);
    await monitor.processVerb(
        Response(),
        HashMap.of({AtConstants.quarantined: AtConstants.quarantined}),
        client);
    await monitor.processAtNotification(
        client, (await notificationManager.get('21'))!);
    final Map<String, dynamic> received = jsonDecode(
        client.lastWrittenData!.replaceFirst('notification:', '').trim());
    expect(received['id'], '21');
    expect(received['quarantined'], true);
  });

  test('A client that does not ask is never sent a quarantined notification',
      () async {
    await heldFromQuarantined('22');
    final DummyInboundConnection client = ownClient();
    final MonitorVerbHandler monitor =
        MonitorVerbHandler(keyValueStore, notificationManager);
    await monitor.processVerb(Response(), HashMap(), client);
    await monitor.processAtNotification(
        client, (await notificationManager.get('22'))!);
    expect(client.lastWrittenData, isNull);
  });

  test(
      'notify:list from a client that does not ask leaves quarantined'
      ' notifications out', () async {
    await heldFromQuarantined('22');
    NotifyListVerbHandler list() =>
        NotifyListVerbHandler(keyValueStore, notificationManager);
    final List<dynamic> notAsked =
        jsonDecode((await clientSends(list, 'notify:list'))!);
    expect(notAsked.map((n) => n['id']), isNot(contains('22')));
    final List<dynamic> asked =
        jsonDecode((await clientSends(list, 'notify:list:quarantined'))!);
    expect(asked.map((n) => n['id']), contains('22'));
  });

  test(
      'notify:fetch from a client that does not ask answers as for no such'
      ' notification', () async {
    await heldFromQuarantined('22');
    expect(
        await clientSends(
            () => NotifyFetchVerbHandler(keyValueStore, notificationManager),
            'notify:fetch:22'),
        '{"id":"22","notificationStatus":"NotificationStatus.expired"}');
  });

  test('Admitting the sender does not rewrite the mark', () async {
    await heldFromQuarantined('21');
    await gate().admit(inv, chuck);
    final Map<String, dynamic> fetched = jsonDecode((await clientSends(
        () => NotifyFetchVerbHandler(keyValueStore, notificationManager),
        'notify:fetch:21:quarantined'))!);
    expect(fetched['id'], '21');
    expect(fetched['quarantined'], true);
  });

  test(
      'Quarantined notifications already held stay, marked, when a namespace'
      ' is closed', () async {
    await heldFromQuarantined('21');
    await gate().setRule(inv, GateMode.closed);
    expect((await notificationManager.get('21'))!.quarantined, isTrue);
  });
}
