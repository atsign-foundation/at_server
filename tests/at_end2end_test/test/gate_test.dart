import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';

import 'e2e_test_utils.dart' as e2e;

/// The gate's scenarios that need two atServers, run across separate hosts,
/// each under its scenario's title.
///
/// Either atServer may run a release without the gate, so each test runs only
/// when the atServers its scenario names answer `gate:`. The atSigns here are
/// shared with other suites, so no test changes an atSign's default: each works
/// in namespaces of its own and removes their rules when it ends. "Authentication
/// is never gated" needs a closed default, and runs in the functional pack.
void main() {
  late String atSign1;
  late String atSign2;
  late e2e.SimpleOutboundConnection sh1;
  late e2e.SimpleOutboundConnection sh2;
  late bool gate1;
  late bool gate2;
  late String ns;

  Future<String> send(e2e.SimpleOutboundConnection sh, String command) async {
    await sh.writeCommand('$command\n');
    return (await sh.read(timeoutMillis: 30000)).trim();
  }

  Future<bool> answersGate(e2e.SimpleOutboundConnection sh) async =>
      (await send(sh, 'gate:default')).startsWith('data:');

  /// The atSign whose gate a test sets and the other atSign, or null when
  /// neither atServer answers `gate:`.
  _Roles? gatedAndOther() {
    if (gate1) return _Roles(atSign1, sh1, atSign2, sh2);
    if (gate2) return _Roles(atSign2, sh2, atSign1, sh1);
    return null;
  }

  /// The status of notification [id] once it stops being queued, or the last
  /// one seen after 60 seconds.
  Future<String> settledStatus(e2e.SimpleOutboundConnection sender, String id) async {
    String status = '';
    for (int i = 0; i < 120; i++) {
      status = (await send(sender, 'notify:status:$id')).replaceFirst('data:', '');
      if (status != 'queued' && status != 'errored') {
        return status;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return status;
  }

  /// A token no earlier run of this pack has used.
  String fresh() =>
      '${DateTime.now().microsecondsSinceEpoch}${Random.secure().nextInt(1 << 32)}';

  Future<String> notifies(
      e2e.SimpleOutboundConnection sender, String recipientAndKey) async {
    final String id = fresh();
    expect(await send(sender, 'notify:id:$id:$recipientAndKey'), 'data:$id');
    return id;
  }

  setUpAll(() async {
    final List<String> atSigns = e2e.knownAtSigns();
    atSign1 = atSigns[0];
    atSign2 = atSigns[1];
    sh1 = await e2e.getSocketHandler(atSign1);
    sh2 = await e2e.getSocketHandler(atSign2);
    gate1 = await answersGate(sh1);
    gate2 = await answersGate(sh2);
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() async {
    await sh1.clear();
    await sh2.clear();
    ns = 'g${fresh()}';
  });

  tearDown(() async {
    for (final e2e.SimpleOutboundConnection sh in [
      if (gate1) sh1,
      if (gate2) sh2,
    ]) {
      for (final String namespace in [ns, 'invitations.$ns']) {
        await send(sh, 'gate:rule:$namespace:none');
        for (final String atSign in [atSign1, atSign2, '@curtly']) {
          await send(sh, 'gate:remove:$namespace:$atSign');
        }
      }
    }
  });

  test('A sending atServer discards a refused notification at once', () async {
    if (!(gate1 && gate2)) {
      markTestSkipped('needs the gate on both atServers');
      return;
    }
    expect(await send(sh1, 'gate:rule:$ns:open:limit:1'), 'data:success');
    final String accepted = await notifies(sh2, '$atSign1:a.$ns$atSign2');
    expect(await settledStatus(sh2, accepted), 'delivered');
    final String refused = await notifies(sh2, '$atSign1:b.$ns$atSign2');
    expect(await settledStatus(sh2, refused), 'refused');
    await Future.delayed(const Duration(seconds: 3));
    expect(await send(sh2, 'notify:status:$refused'), 'data:refused',
        reason: 'a refused notification is not tried again');
  }, timeout: Timeout(Duration(minutes: 3)));

  test('A refusal does not hold back the next notification', () async {
    if (!(gate1 && gate2)) {
      markTestSkipped('needs the gate on both atServers');
      return;
    }
    expect(await send(sh1, 'gate:rule:$ns:closed'), 'data:success');
    expect(await send(sh1, 'gate:rule:invitations.$ns:open'), 'data:success');
    final String refused = await notifies(sh2, '$atSign1:a.$ns$atSign2');
    final String next =
        await notifies(sh2, '$atSign1:b.invitations.$ns$atSign2');
    final Stopwatch sinceSent = Stopwatch()..start();
    expect(await settledStatus(sh2, next), 'delivered');
    expect(sinceSent.elapsed, lessThan(const Duration(seconds: 20)));
    expect(await settledStatus(sh2, refused), 'refused');
  }, timeout: Timeout(Duration(minutes: 3)));

  test('The reply to an invitation arrives in quarantine', () async {
    if (!(gate1 && gate2)) {
      markTestSkipped('needs the gate on both atServers');
      return;
    }
    for (final e2e.SimpleOutboundConnection sh in [sh1, sh2]) {
      expect(await send(sh, 'gate:rule:$ns:closed'), 'data:success');
      expect(await send(sh, 'gate:rule:invitations.$ns:open'), 'data:success');
    }
    final String invitation =
        await notifies(sh1, '$atSign2:inv1.invitations.$ns$atSign1');
    expect(await settledStatus(sh1, invitation), 'delivered');
    final String reply =
        await notifies(sh2, '$atSign1:inv1.invitations.$ns$atSign2');
    expect(await settledStatus(sh2, reply), 'delivered');
    expect(
        await send(sh1, 'gate:check:invitations.$ns:$atSign2'),
        'data:{"namespace":"invitations.$ns","atSign":"$atSign2",'
        '"verdict":"quarantined"}');
  }, timeout: Timeout(Duration(minutes: 3)));

  test('Accepting an invitation is the application admitting the atSign',
      () async {
    final gated = gatedAndOther();
    if (gated == null) {
      markTestSkipped('needs the gate on an atServer');
      return;
    }
    final String alice = gated.gated;
    final e2e.SimpleOutboundConnection aliceSh = gated.gatedSh;
    final String dave = gated.other;
    final e2e.SimpleOutboundConnection daveSh = gated.otherSh;
    expect(await send(aliceSh, 'gate:rule:$ns:closed'), 'data:success');
    expect(await send(aliceSh, 'gate:rule:invitations.$ns:open'),
        'data:success');
    final String quarantined =
        await notifies(daveSh, '$alice:inv1.invitations.$ns$dave');
    expect(await settledStatus(daveSh, quarantined), 'delivered');
    expect(await send(aliceSh, 'gate:admit:$ns:$dave'), 'data:success');
    final String message = await notifies(aliceSh, '$dave:msg.$ns$alice');
    expect(await settledStatus(aliceSh, message), 'delivered');
  }, timeout: Timeout(Duration(minutes: 3)));

  /// What a monitor of [atSign]'s, asking for quarantined notifications when
  /// [quarantined], receives within 15 seconds, replaying from [since].
  Future<List<Map<String, dynamic>>> monitored(String atSign, int since,
      {required bool quarantined}) async {
    final e2e.SimpleOutboundConnection monitor =
        await e2e.getSocketHandler(atSign);
    await monitor
        .writeCommand('monitor${quarantined ? ':quarantined' : ''}:$since\n');
    final List<Map<String, dynamic>> received = [];
    final Stopwatch listening = Stopwatch()..start();
    while (listening.elapsed < const Duration(seconds: 15)) {
      final String line =
          await monitor.read(timeoutMillis: 2000, throwTimeoutException: false);
      if (line.startsWith('notification: ')) {
        received.add(jsonDecode(line.substring('notification: '.length)));
      }
    }
    monitor.close();
    return received;
  }

  /// Sends [alice] a notification from quarantine and one from an admitted
  /// namespace, both from [dave], and answers their ids once delivered.
  Future<List<String>> quarantinedAndAdmitted(
      String alice,
      e2e.SimpleOutboundConnection aliceSh,
      String dave,
      e2e.SimpleOutboundConnection daveSh) async {
    expect(await send(aliceSh, 'gate:rule:invitations.$ns:open'),
        'data:success');
    expect(await send(aliceSh, 'gate:rule:$ns:closed:admit:$dave'),
        'data:success');
    final String fromQuarantine =
        await notifies(daveSh, '$alice:inv.invitations.$ns$dave');
    final String admitted = await notifies(daveSh, '$alice:msg.$ns$dave');
    for (final String id in [fromQuarantine, admitted]) {
      expect(await settledStatus(daveSh, id), 'delivered');
    }
    return [fromQuarantine, admitted];
  }

  test('A client that asks receives quarantined notifications, marked',
      () async {
    final gated = gatedAndOther();
    if (gated == null) {
      markTestSkipped('needs the gate on an atServer');
      return;
    }
    final String alice = gated.gated;
    final e2e.SimpleOutboundConnection aliceSh = gated.gatedSh;
    final String dave = gated.other;
    final e2e.SimpleOutboundConnection daveSh = gated.otherSh;
    final int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    final List<String> ids =
        await quarantinedAndAdmitted(alice, aliceSh, dave, daveSh);
    final String fromQuarantine = ids[0];
    final String admitted = ids[1];
    final List<Map<String, dynamic>> received =
        await monitored(alice, since, quarantined: true);
    expect(received.singleWhere((n) => n['id'] == fromQuarantine)['quarantined'],
        true);
    expect(received.where((n) => n['id'] == admitted), hasLength(1),
        reason: 'the control: the monitor delivers what it was sent');
  }, timeout: Timeout(Duration(minutes: 3)));

  test('A client that does not ask is never sent a quarantined notification',
      () async {
    final gated = gatedAndOther();
    if (gated == null) {
      markTestSkipped('needs the gate on an atServer');
      return;
    }
    final String alice = gated.gated;
    final e2e.SimpleOutboundConnection aliceSh = gated.gatedSh;
    final String dave = gated.other;
    final e2e.SimpleOutboundConnection daveSh = gated.otherSh;
    final int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    final List<String> ids =
        await quarantinedAndAdmitted(alice, aliceSh, dave, daveSh);
    final String fromQuarantine = ids[0];
    final String admitted = ids[1];
    final List<Map<String, dynamic>> received =
        await monitored(alice, since, quarantined: false);
    expect(received.where((n) => n['id'] == admitted), hasLength(1),
        reason: 'the control: the monitor delivers what it was sent');
    expect(received.where((n) => n['id'] == fromQuarantine), isEmpty);
  }, timeout: Timeout(Duration(minutes: 3)));

  test(
      'A key shared with an atSign the namespace refuses is stored, and not'
      ' notified', () async {
    final gated = gatedAndOther();
    if (gated == null) {
      markTestSkipped('needs the gate on an atServer');
      return;
    }
    final String alice = gated.gated;
    final e2e.SimpleOutboundConnection aliceSh = gated.gatedSh;
    final String chuck = gated.other;
    final e2e.SimpleOutboundConnection chuckSh = gated.otherSh;
    final int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    expect(await send(aliceSh, 'gate:rule:$ns:closed:admit:@curtly'),
        'data:success');
    expect(
        int.tryParse((await send(aliceSh, 'update:$chuck:status.$ns$alice v'))
            .replaceFirst('data:', '')),
        isNotNull);
    expect(await send(aliceSh, 'llookup:$chuck:status.$ns$alice'), 'data:v');
    await Future.delayed(const Duration(seconds: 5));
    expect(await send(chuckSh, 'notify:list:$since'),
        isNot(contains('status.$ns')));
    await send(aliceSh, 'delete:$chuck:status.$ns$alice');
  }, timeout: Timeout(Duration(minutes: 3)));

  test('A stored key becomes reachable when its atSign is admitted', () async {
    final gated = gatedAndOther();
    if (gated == null) {
      markTestSkipped('needs the gate on an atServer');
      return;
    }
    final String alice = gated.gated;
    final e2e.SimpleOutboundConnection aliceSh = gated.gatedSh;
    final String chuck = gated.other;
    final e2e.SimpleOutboundConnection chuckSh = gated.otherSh;
    expect(await send(aliceSh, 'gate:rule:$ns:closed:admit:@curtly'),
        'data:success');
    await send(aliceSh, 'update:$chuck:status.$ns$alice v');
    expect(await send(aliceSh, 'gate:admit:$ns:$chuck'), 'data:success');
    expect(await send(chuckSh, 'lookup:bypassCache:true:status.$ns$alice'),
        'data:v');
    await send(aliceSh, 'delete:$chuck:status.$ns$alice');
  }, timeout: Timeout(Duration(minutes: 3)));

  test('A refused cache refresh removes the cached copy', () async {
    if (!(gate1 && gate2)) {
      markTestSkipped('needs the gate on both atServers');
      return;
    }
    if (!(await send(sh2, 'config:set:doCacheRefreshNow=true'))
        .startsWith('data:')) {
      markTestSkipped("@$atSign2's atServer does not take config:set");
      return;
    }
    expect(await send(sh1, 'gate:rule:$ns:closed:admit:$atSign2'),
        'data:success');
    await send(sh1, 'update:ttr:1:$atSign2:status.$ns$atSign1 v');
    expect(await send(sh2, 'lookup:status.$ns$atSign1'), 'data:v');
    final String copy = 'cached:$atSign2:status.$ns$atSign1';
    expect(await send(sh2, 'llookup:$copy'), 'data:v',
        reason: "the holder's atServer must hold the copy before the refresh");
    expect(await send(sh1, 'gate:remove:$ns:$atSign2'), 'data:success');
    await Future.delayed(const Duration(seconds: 2));
    expect(await send(sh2, 'llookup:$copy'), 'data:v',
        reason: 'the copy outlives its ttr until a refresh replaces it');
    expect(await send(sh2, 'config:set:doCacheRefreshNow=true'), 'data:ok');
    String held = '';
    for (int i = 0; i < 60; i++) {
      held = await send(sh2, 'llookup:$copy');
      if (!held.startsWith('data:')) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    expect(held, contains('AT0015'),
        reason: "the refresh must remove the holder's copy");
    await send(sh1, 'delete:$atSign2:status.$ns$atSign1');
  }, timeout: Timeout(Duration(minutes: 3)));
}

/// The atSign whose gate a test sets, the other atSign, and a connection to
/// each.
class _Roles {
  final String gated;
  final e2e.SimpleOutboundConnection gatedSh;
  final String other;
  final e2e.SimpleOutboundConnection otherSh;

  _Roles(this.gated, this.gatedSh, this.other, this.otherSh);
}
