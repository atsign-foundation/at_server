import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/gate/gate_store.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/gate/quarantine.dart';
import 'package:clock/clock.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The gatekeeper's counting of quarantined exchanges, as
/// docs/projects/gatekeeper/features/quarantine.feature relies on it.
void main() {
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();
  final Atsign erin = '@erin'.toAtsign();
  final DateTime start = DateTime.utc(2026, 10, 11, 9, 30);

  late DateTime now;
  Future<T> at<T>(Future<T> Function() f) => withClock(Clock(() => now), f);

  Future<GateVerdict> notify(Gatekeeper gate, Atsign other,
          {String key = 'inv.invitations.chat', int bytes = 100}) =>
      at(() => gate.count(other, key, bytes: bytes));

  Future<Gatekeeper> openInvitations({GateLimits? limits}) async {
    final Gatekeeper gate = Gatekeeper(
        defaultMode: GateDefault.closed,
        limits: limits ?? const GateLimits());
    await gate.setRule('invitations.chat', GateMode.open);
    return gate;
  }

  setUp(() => now = start);

  group('Given an open namespace', () {
    test(
        'when an atSign in none of its sets is counted, then it is quarantined'
        ' from that moment', () async {
      final Gatekeeper gate = await openInvitations();
      expect(await notify(gate, chuck), GateVerdict.quarantined);
      final QuarantineEntry entry =
          (await at(() async => gate.quarantinedIn('invitations.chat')))[
              chuck]!;
      expect(entry.firstContact, start);
      expect(entry.counted.length, 1);
    });

    test(
        'when the limit is reached in the window, then the next is refused and'
        ' not counted', () async {
      final Gatekeeper gate = await openInvitations();
      for (int i = 0; i < 10; i++) {
        await notify(gate, chuck);
      }
      await expectLater(
          notify(gate, chuck), throwsA(isA<QuarantineLimitException>()));
      expect((await at(() async => gate.quarantinedIn('invitations.chat')))[
              chuck]!
          .counted
          .length, 10);
    });

    test('when the oldest leaves the window, then a place is free again',
        () async {
      final Gatekeeper gate = await openInvitations();
      await notify(gate, chuck);
      now = start.add(const Duration(minutes: 1));
      for (int i = 0; i < 9; i++) {
        await notify(gate, chuck);
      }
      now = start.add(const Duration(hours: 24, seconds: 1));
      expect(await notify(gate, chuck), GateVerdict.quarantined);
      await expectLater(
          notify(gate, chuck), throwsA(isA<QuarantineLimitException>()));
    });

    test(
        'when an atSign has nothing counted for a window, then it drops back to'
        ' none', () async {
      final Gatekeeper gate = await openInvitations();
      await notify(gate, chuck);
      now = start.add(const Duration(hours: 24, seconds: 1));
      expect(await at(() async => gate.quarantinedIn('invitations.chat')),
          isEmpty);
      expect(await notify(gate, chuck), GateVerdict.quarantined);
      expect(
          (await at(() async => gate.quarantinedIn('invitations.chat')))[chuck]!
              .firstContact,
          now);
    });

    test(
        'when a notification is over the size cap, then it is refused and not'
        ' counted; one at the cap is counted', () async {
      final Gatekeeper gate = await openInvitations();
      await expectLater(notify(gate, chuck, bytes: 15361),
          throwsA(isA<QuarantineSizeException>()));
      expect(await at(() async => gate.quarantinedIn('invitations.chat')),
          isEmpty);
      expect(await notify(gate, chuck, bytes: 15360), GateVerdict.quarantined);
    });

    test(
        'when its bound on quarantined atSigns is reached, then a new atSign is'
        ' refused and one already quarantined is still counted', () async {
      final Gatekeeper gate = await openInvitations();
      await gate.setRule('invitations.chat', GateMode.open,
          setting: GateSetting.maxQuarantined, value: 2);
      await notify(gate, chuck);
      await notify(gate, dave);
      await expectLater(
          notify(gate, erin), throwsA(isA<QuarantineLimitException>()));
      expect(await notify(gate, chuck), GateVerdict.quarantined);
      expect(
          (await at(() async => gate.quarantinedIn('invitations.chat')))
              .keys
              .toSet(),
          {chuck, dave});
    });

    test(
        'when the bytes accepted in the window reach its bound, then the next'
        ' notification is refused, and a lookup still counts', () async {
      final Gatekeeper gate = await openInvitations();
      await gate.setRule('invitations.chat', GateMode.open,
          setting: GateSetting.maxQuarantinedBytes, value: 1000);
      await notify(gate, chuck, bytes: 600);
      await notify(gate, dave, bytes: 400);
      await expectLater(notify(gate, chuck, bytes: 1),
          throwsA(isA<QuarantineLimitException>()));
      expect(
          await at(() => gate.count(chuck, 'profile.invitations.chat')),
          GateVerdict.quarantined);
    });

    test(
        'when the atSign-wide total is reached, then a notification in another'
        ' namespace is refused', () async {
      final Gatekeeper gate = await openInvitations(
          limits: const GateLimits(maxQuarantinedBytesEverywhere: 1000));
      await gate.setRule('photos', GateMode.open);
      await notify(gate, chuck, bytes: 1000);
      await expectLater(notify(gate, erin, key: 'pic.photos', bytes: 1),
          throwsA(isA<QuarantineLimitException>()));
    });

    test('when an atSign is counted in two namespaces, then each counts alone',
        () async {
      final Gatekeeper gate = await openInvitations();
      await gate.setRule('photos', GateMode.open);
      for (int i = 0; i < 10; i++) {
        await notify(gate, chuck);
      }
      expect(await notify(gate, chuck, key: 'pic.photos'),
          GateVerdict.quarantined);
    });

    test('when two exchanges at the limit are counted at once, then one is',
        () async {
      final Gatekeeper gate =
          Gatekeeper(defaultMode: GateDefault.closed, store: _SlowStore());
      await gate.setRule('invitations.chat', GateMode.open);
      for (int i = 0; i < 9; i++) {
        await notify(gate, chuck);
      }
      final List<Object> outcomes = await Future.wait([
        notify(gate, chuck).then<Object>((v) => v, onError: (Object e) => e),
        notify(gate, chuck).then<Object>((v) => v, onError: (Object e) => e),
      ]);
      expect(outcomes.whereType<GateVerdict>().length, 1);
      expect(outcomes.whereType<QuarantineLimitException>().length, 1);
    });

    test(
        'when it is closed and opened again, then its quarantine starts again',
        () async {
      final Gatekeeper gate = await openInvitations();
      for (int i = 0; i < 10; i++) {
        await notify(gate, chuck);
      }
      await gate.setRule('invitations.chat', GateMode.closed);
      await gate.setRule('invitations.chat', GateMode.open);
      expect(await notify(gate, chuck), GateVerdict.quarantined);
      expect(
          (await at(() async => gate.quarantinedIn('invitations.chat')))[chuck]!
              .counted
              .length,
          1);
    });

    test('when its rule is removed, then its quarantine goes', () async {
      final Gatekeeper gate = await openInvitations();
      await notify(gate, chuck);
      await gate.removeRule('invitations.chat');
      await gate.setRule('invitations.chat', GateMode.open);
      expect(await at(() async => gate.quarantinedIn('invitations.chat')),
          isEmpty);
    });

    for (final (String how, Future<void> Function(Gatekeeper) change) in [
      ('admitted there', (g) => g.admit('invitations.chat', chuck)),
      ('denied there', (g) => g.deny('invitations.chat', chuck)),
      ('admitted atSign-wide', (g) => g.admit(Gatekeeper.everyNamespace, chuck)),
    ]) {
      test('when a quarantined atSign is $how, then its counting ends',
          () async {
        final Gatekeeper gate = await openInvitations();
        await notify(gate, chuck);
        await change(gate);
        expect(
            (await at(() async => gate.quarantinedIn('invitations.chat')))
                .containsKey(chuck),
            isFalse);
      });
    }

    test(
        'when it is shown, then its quarantined atSigns come in order of first'
        ' contact, each with its count, bytes and first contact', () async {
      final Gatekeeper gate = await openInvitations();
      await notify(gate, erin, bytes: 10);
      now = start.add(const Duration(minutes: 5));
      await notify(gate, dave, bytes: 20);
      await notify(gate, erin, bytes: 30);
      expect(
          (await at(() async => gate.show('invitations.chat')))['quarantined'],
          [
            {
              'atSign': '@erin',
              'counted': 2,
              'bytes': 40,
              'firstContact': '2026-10-11T09:30:00.000Z'
            },
            {
              'atSign': '@dave',
              'counted': 1,
              'bytes': 20,
              'firstContact': '2026-10-11T09:35:00.000Z'
            },
          ]);
    });
  });

  group('Given a quarantine kept in the keystore', () {
    setUpAll(() async => await verbTestsSetUpAll());
    setUp(() async => await verbTestsSetUp());
    tearDown(() async => await verbTestsTearDown());

    test('when the gate is loaded again, then its counts are as they were',
        () async {
      final Gatekeeper gate = await Gatekeeper.load(
          GateStore(keyValueStore, alice),
          startingDefault: GateDefault.closed);
      await gate.setRule('invitations.chat', GateMode.open);
      for (int i = 0; i < 10; i++) {
        await notify(gate, chuck, bytes: 7);
      }
      final Gatekeeper again =
          await Gatekeeper.load(GateStore(keyValueStore, alice));
      final QuarantineEntry entry =
          (await at(() async => again.quarantinedIn('invitations.chat')))[
              chuck]!;
      expect(entry.counted.length, 10);
      expect(entry.bytes, 70);
      expect(entry.firstContact, start);
      await expectLater(
          notify(again, chuck), throwsA(isA<QuarantineLimitException>()));
    });
  });
}

/// A store whose writes succeed after a pause, as a keystore's do, so that
/// two changes would interleave without the gatekeeper's lock.
class _SlowStore extends Fake implements GateStore {
  Future<void> _pause() => Future.delayed(const Duration(milliseconds: 5));

  @override
  Future<void> putRule(String namespace, GateRule rule) => _pause();

  @override
  Future<void> putQuarantine(
          String namespace, Map<Atsign, QuarantineEntry> entries) =>
      _pause();

  @override
  Future<void> deleteQuarantine(String namespace) => _pause();
}
