import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'telemetry_test_support.dart';
import 'test_utils.dart';

/// Catalogue: features/notify/notification_id_length_bound.feature
void main() {
  const String id36 = '6f1f6e2c-3d0b-4a8e-9b51-2b7e0c4d9a13';
  const String id37 = '${id36}0';

  late AtServerTelemetry telemetry;
  late RecordingExporter exporter;

  String clientNotify(String id) =>
      'notify:id:$id:update:@bob:phone.wavi@alice:v';
  String peerNotify(String id) =>
      'notify:id:$id:update:messageType:key:ttln:60000:@alice:phone.wavi@bob:v';

  Future<List<String>> storedIds() async =>
      [await for (final n in notifStore.iterate()) n.id!];

  Future<DummyInboundConnection> monitor() async {
    final DummyInboundConnection connection = DummyInboundConnection();
    connection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    await MonitorVerbHandler(keyValueStore, notificationManager)
        .processVerb(Response(), HashMap<String, String?>(), connection);
    return connection;
  }

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await setUpAtSignBound();
    telemetry = notificationManager.telemetry!;
    exporter = RecordingExporter();
    enableRecording(telemetry, exporter);
  });

  tearDown(() async {
    await telemetry.shutdown();
    await verbTestsTearDown();
  });

  test("A client's notify whose id has more than 36 characters is refused",
      () async {
    final Connection connection = aliceClient();
    final List<Object?> before = await footprint();

    await send(clientNotify(id37), connection);

    expect(connection.writes, [
      'error:AT0003-Invalid syntax : notification id must have at most 36'
          ' characters\n@alice@'
    ]);
    expect(await footprint(), before);
    expect(await sentTo('@bob'), isEmpty);
    expect(connection.closeCount, 0);
  });

  test("A peer's notify whose id has more than 36 characters is refused",
      () async {
    final DummyInboundConnection monitoring = await monitor();
    final Connection connection = peer(bob);
    final List<Object?> before = await footprint();

    await send(peerNotify(id37), connection);
    await pumpEventQueue();

    expect(connection.writes, [
      'error:AT0003-Exception: notification id must have at most 36'
          ' characters\n@'
    ]);
    expect(await footprint(), before);
    expect(monitoring.lastWrittenData, isNull);
    expect(
        eventNames(exporter.records,
            prefix: '$atServerTelemetryEventPrefix.notification.'),
        isEmpty);
    expect(connection.closeCount, 0);
  });

  group('A notify whose id has exactly 36 characters is accepted', () {
    test("@alice's authenticated client", () async {
      await send(clientNotify(id36), aliceClient());

      expect(await storedIds(), [id36]);
    });

    test('a peer that has proved itself as @bob by pol', () async {
      final DummyInboundConnection monitoring = await monitor();

      await send(peerNotify(id36), peer(bob));
      await pumpEventQueue();

      expect(await storedIds(), [id36]);
      expect(monitoring.lastWrittenData, contains(id36),
          reason: 'a monitor is pushed an accepted notification');
      expect(
          eventNames(exporter.records), [atServerNotificationReceivedEventName],
          reason: 'an accepted notification is reported');
    });
  });

  test(
      'A connection that has not authenticated is answered as today whatever the id',
      () async {
    final Connection longId = unauthenticated();
    final Connection shortId = unauthenticated();

    await send(clientNotify(id37), longId);
    await send(clientNotify(id36), shortId);

    expect(longId.writes.single, startsWith('error:AT0401-'));
    expect(longId.writes, shortId.writes);
    expect(longId.closeCount, shortId.closeCount);
  });
}
