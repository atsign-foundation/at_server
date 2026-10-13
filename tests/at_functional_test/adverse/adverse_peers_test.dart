/// Catalogue: features/outbound/adverse_peers.feature
///
/// Run by runAdverse.sh, which starts the virtualenv and the fault proxy and
/// points @alice🛠's atDirectory record at the proxy.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'at_wire.dart';

const String _host = 'vip.ve.atsign.zone';
const String _alice = '@alice🛠';
const String _bob = '@bob🛠';
const String _aliceProgram = '25000_@alice🛠';
const String _lookup = 'lookup:bypassCache:true:lookup0.gatebench$_alice';
const Timeout _generous = Timeout(Duration(minutes: 3));

void main() {
  final int base = int.parse(Platform.environment['VIRTUALENV_BASE_PORT']!);
  final String container = Platform.environment['ADVERSE_CONTAINER']!;
  final int alicePort = base + 1;
  final int bobPort = base + 4;
  final int controlPort = base + 90;

  Future<AtWire> alice() => AtWire.authenticated(_alice, _host, alicePort);
  Future<AtWire> bob() => AtWire.authenticated(_bob, _host, bobPort);

  /// Sends the lookup on [wire], printing how long it took and its answer.
  Future<(String, int)> timedLookup(AtWire wire, String label) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final String line = await wire.request(_lookup);
    final int millis = stopwatch.elapsedMilliseconds;
    print('MEASURE $label ${millis}ms $line');
    return (line, millis);
  }

  setUpAll(() async {
    final AtWire owner = await alice();
    final String stored = await owner
        .request('update:$_bob:lookup0.gatebench$_alice value');
    expect(stored, startsWith('data:'));
    await owner.close();

    await setFault(controlPort, 'pass');
    final AtWire client = await bob();
    expect((await timedLookup(client, 'background')).$1, 'data:value');
    await client.close();
    final String stats = await setFault(controlPort, 'stats');
    print('fault proxy after the background lookup: $stats');
    expect(stats, isNot('ok connections=0'),
        reason: "@bob🛠's atServer must reach @alice🛠's through the proxy,"
            ' or no scenario here tests anything');
  });

  setUp(() async {
    await setFault(controlPort, 'pass');
  });

  tearDown(() async {
    await supervisor(container, ['signal', 'CONT', _aliceProgram]);
    await setFault(controlPort, 'pass');
  });

  test('A lookup through added latency answers the value', () async {
    final AtWire client = await bob();
    expect((await timedLookup(client, 'warm')).$1, 'data:value');
    await setFault(controlPort, 'delay 100 50');

    expect((await timedLookup(client, 'latency')).$1, 'data:value');
    await client.close();
  }, timeout: _generous);

  test('A reply delivered one byte at a time is answered whole', () async {
    final AtWire client = await bob();
    expect((await timedLookup(client, 'warm')).$1, 'data:value');
    await setFault(controlPort, 'trickle 20');

    final String before = await setFault(controlPort, 'stats');
    expect((await timedLookup(client, 'trickle')).$1, 'data:value');
    print('MEASURE trickle proxy before: $before;'
        ' after: ${await setFault(controlPort, 'stats')}');
    await client.close();
  }, timeout: _generous);

  test(
      'A reply that stops arriving fails as the inter-chunk budget passes, and'
      ' the next lookup succeeds', () async {
    final AtWire client = await bob();
    expect((await timedLookup(client, 'warm')).$1, 'data:value');
    await setFault(controlPort, 'stall');

    final (String line, int millis) = await timedLookup(client, 'stall');
    expect(line, startsWith('error:'));
    expect(millis, inInclusiveRange(10000, 13000));

    await setFault(controlPort, 'pass');
    expect((await timedLookup(client, 'after-stall')).$1, 'data:value');
    await client.close();
  }, timeout: _generous);

  test(
      'The remote atServer hanging up mid-reply fails the lookup at once, and'
      ' the next lookup succeeds', () async {
    final AtWire client = await bob();
    expect((await timedLookup(client, 'warm')).$1, 'data:value');
    await setFault(controlPort, 'hangup');

    final (String line, int millis) = await timedLookup(client, 'hangup');
    expect(line, startsWith('error:'));
    expect(millis, lessThan(1000));

    expect((await timedLookup(client, 'after-hangup')).$1, 'data:value');
    await client.close();
  }, timeout: _generous);

  test(
      'A remote atServer that freezes fails the lookup as the inter-chunk'
      ' budget passes, and is reached again once it resumes', () async {
    final AtWire client = await bob();
    expect((await timedLookup(client, 'warm')).$1, 'data:value');
    await supervisor(container, ['signal', 'STOP', _aliceProgram]);

    final (String line, int millis) = await timedLookup(client, 'freeze');
    expect(line, startsWith('error:'));
    expect(millis, inInclusiveRange(10000, 13000));

    await supervisor(container, ['signal', 'CONT', _aliceProgram]);
    expect((await timedLookup(client, 'after-freeze')).$1, 'data:value');
    await client.close();
  }, timeout: _generous);

  test('A remote atServer that restarts is reached again', () async {
    final AtWire client = await bob();
    expect((await timedLookup(client, 'warm')).$1, 'data:value');
    final int pidBefore =
        supervisedPid(await supervisor(container, ['status', _aliceProgram]));
    await supervisor(container, ['restart', _aliceProgram]);
    final int pidAfter =
        supervisedPid(await supervisor(container, ['status', _aliceProgram]));
    print('MEASURE restart pid $pidBefore -> $pidAfter');
    expect(pidAfter, isNot(pidBefore),
        reason: "@alice🛠's atServer must really have restarted");

    final Stopwatch sinceRestart = Stopwatch()..start();
    int attempts = 0;
    String line = '';
    while (sinceRestart.elapsed < const Duration(seconds: 30)) {
      attempts++;
      line = (await timedLookup(client, 'after-restart-$attempts')).$1;
      if (line == 'data:value') {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    print('MEASURE restart answered after ${sinceRestart.elapsedMilliseconds}ms'
        ' and $attempts attempts');
    expect(line, 'data:value');
    expect(sinceRestart.elapsed, lessThan(const Duration(seconds: 30)));
    await client.close();
  }, timeout: _generous);

  /// Sends [count] notifications from @bob🛠 to @alice🛠 and waits for each at
  /// @alice🛠's monitor, then for any duplicate. [beforeSending] runs once the
  /// monitor is listening, [afterSending] once every notification has been
  /// accepted, and [bound] runs from the end of [afterSending].
  Future<void> notifyAndCount(int count, Duration bound,
      {Future<void> Function()? beforeSending,
      Future<void> Function(int Function() arrivedSoFar)? afterSending,
      required String label}) async {
    final AtWire monitor = await alice();
    final String tag = const Uuid().v4().substring(0, 8);
    final Map<String, int> arrivals = {};
    final Completer<void> allArrived = Completer();
    final Set<String> sent = {};
    final StreamSubscription<String> subscription =
        monitor.notifications.listen((json) {
      final Map<String, dynamic> notification = jsonDecode(json);
      final String id = notification['id'] as String;
      if (!sent.contains(id)) {
        return;
      }
      arrivals[id] = (arrivals[id] ?? 0) + 1;
      if (arrivals.length == count && !allArrived.isCompleted) {
        allArrived.complete();
      }
    });
    monitor.send('monitor gatebench');

    final AtWire client = await bob();
    await beforeSending?.call();
    for (int i = 0; i < count; i++) {
      final String id = const Uuid().v4();
      sent.add(id);
      final String answer = await client.request(
          'notify:id:$id:update:$_alice:n$tag-$i.gatebench$_bob:v');
      expect(answer, 'data:$id');
    }
    await afterSending?.call(() => arrivals.length);
    final Stopwatch waited = Stopwatch()..start();
    await allArrived.future.timeout(bound,
        onTimeout: () => fail('${count - arrivals.length} of $count'
            ' notifications had not arrived after $bound'));
    print('MEASURE $label all $count arrived ${waited.elapsedMilliseconds}ms'
        ' after the wait began');
    await Future.delayed(const Duration(seconds: 2));

    expect(arrivals.keys.toSet(), sent);
    expect(arrivals.values.where((n) => n != 1), isEmpty,
        reason: 'each notification must arrive exactly once');
    await subscription.cancel();
    await monitor.close();
    await client.close();
  }

  test('Notifications through added latency each arrive once', () async {
    await setFault(controlPort, 'delay 100 50');
    await notifyAndCount(50, const Duration(seconds: 60), label: 'latency');
  }, timeout: _generous);

  test(
      'Notifications sent while the remote atServer is frozen each arrive once'
      ' after it resumes', () async {
    await notifyAndCount(20, const Duration(seconds: 30),
        label: 'frozen',
        beforeSending: () =>
            supervisor(container, ['signal', 'STOP', _aliceProgram]),
        afterSending: (arrivedSoFar) async {
      await Future.delayed(const Duration(seconds: 3));
      expect(arrivedSoFar(), 0,
          reason: "nothing can arrive while @alice🛠's atServer is frozen,"
              ' or this scenario is not testing a freeze');
      await supervisor(container, ['signal', 'CONT', _aliceProgram]);
    });
  }, timeout: _generous);
}
