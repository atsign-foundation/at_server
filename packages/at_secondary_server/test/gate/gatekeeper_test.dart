import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:test/test.dart';

/// The gate's decision table, as the scenarios in
/// docs/projects/gatekeeper/features rely on it.
void main() {
  final Atsign bob = '@bob'.toAtsign();
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();

  group('Given the ungated default and no rule', () {
    test('when an atSign reaches a namespace, then it is admitted', () {
      expect(Gatekeeper().inbound(chuck, 'pic.photos'), GateVerdict.admitted);
    });

    test('when an atSign sends a namespace-less key, then it is admitted', () {
      expect(Gatekeeper().inbound(chuck, 'location'), GateVerdict.admitted);
    });
  });

  group('Given the closed default and no rule', () {
    late Gatekeeper gate;
    setUp(() => gate = Gatekeeper(defaultMode: GateDefault.closed));

    test('when an atSign reaches a namespace, then it is not accepted', () {
      expect(gate.inbound(chuck, 'pic.photos'), GateVerdict.notAccepted);
    });

    test(
        'when an atSign admitted somewhere sends a namespace-less exchange on'
        ' the short list, then it is admitted', () async {
      await gate.setRule('chat', GateMode.closed, admit: dave);
      expect(gate.inbound(dave, 'shared_key', onShortList: true),
          GateVerdict.admitted);
    });

    test(
        'when an atSign admitted somewhere sends a namespace-less exchange off'
        ' the short list, then it is not accepted', () async {
      await gate.setRule('chat', GateMode.closed, admit: dave);
      expect(gate.inbound(dave, 'location'), GateVerdict.notAccepted);
    });

    test(
        'when an atSign only quarantined somewhere sends a namespace-less'
        ' exchange on the short list, then it is not accepted', () async {
      await gate.setRule('invitations.chat', GateMode.open);
      expect(gate.inbound(chuck, 'inv.invitations.chat'),
          GateVerdict.quarantined);
      expect(gate.inbound(chuck, 'shared_key', onShortList: true),
          GateVerdict.notAccepted);
    });

    test(
        'when an atSign admitted only atSign-wide sends a namespace-less'
        ' exchange on the short list, then it is admitted', () async {
      await gate.admit(Gatekeeper.everyNamespace, dave);
      expect(gate.inbound(dave, 'shared_key', onShortList: true),
          GateVerdict.admitted);
    });
  });

  group('Given a closed namespace admitting only @bob', () {
    late Gatekeeper gate;
    setUp(() async {
      gate = Gatekeeper();
      await gate.setRule('chat', GateMode.closed, admit: bob);
    });

    test('when @bob reaches it, then it is admitted', () {
      expect(gate.inbound(bob, 'msg.chat'), GateVerdict.admitted);
    });

    test('when another atSign reaches it, then it is not accepted', () {
      expect(gate.inbound(chuck, 'msg.chat'), GateVerdict.notAccepted);
    });

    test(
        'when an atSign admitted atSign-wide reaches it, then it is not'
        ' accepted', () async {
      await gate.admit(Gatekeeper.everyNamespace, dave);
      expect(gate.inbound(dave, 'msg.chat'), GateVerdict.notAccepted);
    });

    test('when a key beneath it is reached, then its rule decides', () {
      expect(gate.inbound(chuck, 'msg.group.chat'), GateVerdict.notAccepted);
    });

    test(
        'when a more specific open rule covers the key, then that rule'
        ' decides', () async {
      await gate.setRule('invitations.chat', GateMode.open);
      expect(gate.inbound(chuck, 'inv1.invitations.chat'),
          GateVerdict.quarantined);
    });

    test(
        'when it is set closed again, then its admitted set stays and @dave'
        ' is admitted too', () async {
      await gate.setRule('chat', GateMode.closed, admit: dave);
      expect(gate.inbound(bob, 'msg.chat'), GateVerdict.admitted);
      expect(gate.inbound(dave, 'msg.chat'), GateVerdict.admitted);
    });
  });

  group('Given an open namespace', () {
    late Gatekeeper gate;
    setUp(() async {
      gate = Gatekeeper(defaultMode: GateDefault.closed);
      await gate.setRule('photos', GateMode.open);
    });

    test('when an atSign in none of its sets reaches it, then it is'
        ' quarantined', () {
      expect(gate.inbound(chuck, 'pic.photos'), GateVerdict.quarantined);
    });

    test('when an admitted atSign reaches it, then it is admitted', () async {
      await gate.admit('photos', bob);
      expect(gate.inbound(bob, 'pic.photos'), GateVerdict.admitted);
    });

    test('when a denied atSign reaches it, then it is not accepted', () async {
      await gate.deny('photos', chuck);
      expect(gate.inbound(chuck, 'pic.photos'), GateVerdict.notAccepted);
    });

    test(
        'when an atSign admitted atSign-wide reaches it, then it is admitted',
        () async {
      await gate.admit(Gatekeeper.everyNamespace, bob);
      expect(gate.inbound(bob, 'pic.photos'), GateVerdict.admitted);
    });

    test(
        'when an atSign admitted atSign-wide is denied there, then the deny'
        ' decides', () async {
      await gate.admit(Gatekeeper.everyNamespace, bob);
      await gate.deny('photos', bob);
      expect(gate.inbound(bob, 'pic.photos'), GateVerdict.notAccepted);
    });

    test(
        'when an atSign admitted in another namespace reaches it, then it is'
        ' quarantined', () async {
      await gate.setRule('chat', GateMode.open);
      await gate.admit('chat', bob);
      expect(gate.inbound(bob, 'pic.photos'), GateVerdict.quarantined);
    });

    test(
        'when it is closed, then its denied set goes and only its admitted'
        ' atSigns get in', () async {
      await gate.admit('photos', bob);
      await gate.deny('photos', chuck);
      await gate.setRule('photos', GateMode.closed);
      expect(gate.ruleFor('photos')!.denied, isEmpty);
      expect(gate.inbound(bob, 'pic.photos'), GateVerdict.admitted);
      expect(gate.inbound(chuck, 'pic.photos'), GateVerdict.notAccepted);
      expect(gate.inbound(dave, 'pic.photos'), GateVerdict.notAccepted);
    });

    test('when two atSigns are admitted at once, then both are admitted',
        () async {
      await Future.wait([gate.admit('photos', bob), gate.admit('photos', dave)]);
      expect(gate.ruleFor('photos')!.admitted, {bob, dave});
    });
  });

  group('Given a namespace with no rule', () {
    test('when an atSign is admitted, denied or removed in it, then it is'
        ' refused as an illegal argument', () {
      final Gatekeeper gate = Gatekeeper();
      expect(() => gate.admit('chat', bob),
          throwsA(isA<IllegalArgumentException>()));
      expect(() => gate.deny('chat', bob),
          throwsA(isA<IllegalArgumentException>()));
      expect(() => gate.remove('chat', bob),
          throwsA(isA<IllegalArgumentException>()));
    });
  });

  group('Given a closed namespace', () {
    test('when an atSign is denied in it, then it is refused as an illegal'
        ' argument', () async {
      final Gatekeeper gate = Gatekeeper();
      await gate.setRule('chat', GateMode.closed);
      expect(() => gate.deny('chat', bob),
          throwsA(isA<IllegalArgumentException>()));
    });
  });

  group('Given the atSign-wide set', () {
    test('when an atSign is denied in it, then it is refused as an illegal'
        ' argument', () {
      expect(() => Gatekeeper().deny(Gatekeeper.everyNamespace, bob),
          throwsA(isA<IllegalArgumentException>()));
    });

    test('when an atSign is admitted and then removed, then it is admitted'
        ' nowhere', () async {
      final Gatekeeper gate = Gatekeeper();
      await gate.admit(Gatekeeper.everyNamespace, bob);
      await gate.remove(Gatekeeper.everyNamespace, bob);
      expect(gate.admittedEverywhere, isEmpty);
    });
  });

  group('Given an open namespace with settings', () {
    late Gatekeeper gate;
    setUp(() async {
      gate = Gatekeeper();
      await gate.setRule('invitations.chat', GateMode.open,
          setting: GateSetting.limit, value: 3);
    });

    test('when another setting is set, then the first keeps its value',
        () async {
      await gate.setRule('invitations.chat', GateMode.open,
          setting: GateSetting.size, value: 1024);
      final GateRule rule = gate.ruleFor('invitations.chat')!;
      expect(gate.settingOf(rule, GateSetting.limit), 3);
      expect(gate.settingOf(rule, GateSetting.size), 1024);
      expect(gate.settingOf(rule, GateSetting.window), 24 * 60 * 60);
    });

    test('when it is closed and opened again, then its settings are kept',
        () async {
      await gate.setRule('invitations.chat', GateMode.closed);
      await gate.setRule('invitations.chat', GateMode.open);
      expect(
          gate.settingOf(gate.ruleFor('invitations.chat')!, GateSetting.limit),
          3);
    });
  });

  group("Given the operator's bounds", () {
    test(
        'when a setting is set above its ceiling or below its floor, then it'
        ' is refused as an illegal argument and the rule is unchanged',
        () async {
      final Gatekeeper gate = Gatekeeper();
      await gate.setRule('invitations.chat', GateMode.open);
      for (final (GateSetting setting, int value) in [
        (GateSetting.limit, 101),
        (GateSetting.size, 65537),
        (GateSetting.maxQuarantined, 1001),
        (GateSetting.maxQuarantinedBytes, 16 * 1024 * 1024 + 1),
        (GateSetting.window, 3599),
      ]) {
        await expectLater(
            gate.setRule('invitations.chat', GateMode.open,
                setting: setting, value: value),
            throwsA(isA<IllegalArgumentException>()),
            reason: '${setting.name} $value');
        expect(gate.ruleFor('invitations.chat')!.settings, isEmpty);
      }
    });

    test(
        'when an atSign at its cap of open namespaces opens another, then it'
        ' is refused and that namespace has no rule', () async {
      final Gatekeeper gate =
          Gatekeeper(limits: const GateLimits(maxOpenNamespaces: 2));
      await gate.setRule('a.chat', GateMode.open);
      await gate.setRule('b.chat', GateMode.open);
      await expectLater(gate.setRule('c.chat', GateMode.open),
          throwsA(isA<IllegalArgumentException>()));
      expect(gate.ruleFor('c.chat'), isNull);
      await gate.setRule('a.chat', GateMode.open,
          setting: GateSetting.limit, value: 5);
      await gate.setRule('c.chat', GateMode.closed);
      expect(gate.ruleFor('c.chat')!.mode, GateMode.closed);
    });
  });

  group('Given a gate to show', () {
    test('when a namespace has no rule, then it shows its mode as none and the'
        ' default', () {
      expect(Gatekeeper(defaultMode: GateDefault.closed).show('photos'),
          {'namespace': 'photos', 'mode': 'none', 'default': 'closed'});
    });

    test('when a namespace is closed, then it shows only its admitted set',
        () async {
      final Gatekeeper gate = Gatekeeper();
      await gate.setRule('chat', GateMode.closed, admit: dave);
      await gate.admit('chat', bob);
      expect(gate.show('chat'), {
        'namespace': 'chat',
        'mode': 'closed',
        'admitted': ['@bob', '@dave'],
      });
    });

    test('when a namespace is open, then it shows its settings in force and'
        ' its sets', () async {
      final Gatekeeper gate = Gatekeeper();
      await gate.setRule('invitations.chat', GateMode.open,
          setting: GateSetting.limit, value: 3);
      await gate.admit('invitations.chat', bob);
      await gate.deny('invitations.chat', chuck);
      expect(gate.show('invitations.chat'), {
        'namespace': 'invitations.chat',
        'mode': 'open',
        'settings': {
          'limit': 3,
          'window': 86400,
          'size': 15360,
          'maxQuarantined': 100,
          'maxQuarantinedBytes': 1048576,
        },
        'admitted': ['@bob'],
        'denied': ['@chuck'],
        'quarantined': <Object>[],
      });
    });
  });
}
