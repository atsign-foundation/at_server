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
        'when it is closed, then only its admitted atSigns get in and its'
        ' denied set is kept', () async {
      await gate.admit('photos', bob);
      await gate.deny('photos', chuck);
      await gate.setRule('photos', GateMode.closed);
      expect(gate.ruleFor('photos')!.denied, {chuck});
      expect(gate.inbound(bob, 'pic.photos'), GateVerdict.admitted);
      expect(gate.inbound(chuck, 'pic.photos'), GateVerdict.notAccepted);
      expect(gate.inbound(dave, 'pic.photos'), GateVerdict.notAccepted);
    });

    test(
        'when it is closed and opened again, then the atSigns it denied are'
        ' refused', () async {
      await gate.deny('photos', chuck);
      await gate.setRule('photos', GateMode.closed);
      await gate.setRule('photos', GateMode.open);
      expect(gate.inbound(chuck, 'pic.photos'), GateVerdict.notAccepted);
      expect(gate.inbound(dave, 'pic.photos'), GateVerdict.quarantined);
    });

    test('when two atSigns are admitted at once, then both are admitted',
        () async {
      await Future.wait([gate.admit('photos', bob), gate.admit('photos', dave)]);
      expect(gate.ruleFor('photos')!.admitted, {bob, dave});
    });
  });

  group('Given a namespace with no rule', () {
    late Gatekeeper gate;
    setUp(() => gate = Gatekeeper());

    test(
        'when an atSign is admitted in it, then the admission is recorded'
        ' without a rule', () async {
      await gate.admit('chat', bob);
      expect(gate.ruleFor('chat')!.mode, isNull);
      expect(gate.ruleFor('chat')!.admitted, {bob});
      expect(gate.namespaces, ['chat']);
    });

    test(
        'when an atSign is denied in it, then it is refused as an illegal'
        ' argument and nothing is recorded', () async {
      await expectLater(
          gate.deny('chat', bob), throwsA(isA<IllegalArgumentException>()));
      expect(gate.ruleFor('chat'), isNull);
    });

    test('when an atSign is removed from it, then nothing is recorded',
        () async {
      await gate.remove('chat', bob);
      expect(gate.ruleFor('chat'), isNull);
    });

    test(
        'when the last admission recorded in it is removed, then the namespace'
        ' is forgotten', () async {
      await gate.admit('chat', bob);
      await gate.admit('chat', dave);
      await gate.remove('chat', bob);
      expect(gate.ruleFor('chat')!.admitted, {dave});
      await gate.remove('chat', dave);
      expect(gate.ruleFor('chat'), isNull);
      expect(gate.namespaces, isEmpty);
    });

    test('when a rule is set on it, then the rule starts from its admissions',
        () async {
      await gate.admit('chat', bob);
      await gate.setRule('chat', GateMode.open);
      expect(gate.ruleFor('chat')!.mode, GateMode.open);
      expect(gate.ruleFor('chat')!.admitted, {bob});
    });
  });

  group('Given admissions recorded without a rule, under the closed default',
      () {
    late Gatekeeper gate;
    setUp(() async {
      gate = Gatekeeper(defaultMode: GateDefault.closed);
      await gate.admit('chat', bob);
    });

    test('when an atSign recorded there reaches it, then it is admitted', () {
      expect(gate.inbound(bob, 'msg.chat'), GateVerdict.admitted);
    });

    test('when another atSign reaches it, then it is not accepted', () {
      expect(gate.inbound(chuck, 'msg.chat'), GateVerdict.notAccepted);
    });

    test(
        'when a namespace beneath it with no rule is reached, then its'
        ' admissions decide', () {
      expect(gate.inbound(bob, 'msg.group.chat'), GateVerdict.admitted);
      expect(gate.inbound(chuck, 'msg.group.chat'), GateVerdict.notAccepted);
    });

    test(
        'when a more specific namespace has admissions recorded too, then'
        ' both count', () async {
      await gate.admit('invitations.chat', dave);
      expect(gate.inbound(dave, 'inv1.invitations.chat'), GateVerdict.admitted);
      expect(gate.inbound(bob, 'inv1.invitations.chat'), GateVerdict.admitted);
      expect(gate.inbound(dave, 'msg.chat'), GateVerdict.notAccepted);
    });

    test(
        'when a rule is set beneath it, then the rule starts from its own'
        ' namespace and refuses @bob', () async {
      await gate.setRule('invitations.chat', GateMode.closed);
      expect(gate.inbound(bob, 'inv1.invitations.chat'),
          GateVerdict.notAccepted);
      expect(gate.inbound(bob, 'msg.chat'), GateVerdict.admitted);
    });

    test(
        'when an atSign admitted atSign-wide reaches it, or a namespace with'
        ' nothing recorded, then it is admitted', () async {
      await gate.admit(Gatekeeper.everyNamespace, dave);
      expect(gate.inbound(dave, 'msg.chat'), GateVerdict.admitted);
      expect(gate.inbound(dave, 'pic.photos'), GateVerdict.admitted);
      expect(gate.inbound(chuck, 'pic.photos'), GateVerdict.notAccepted);
    });

    test('when a rule covers a namespace beneath it, then the rule decides',
        () async {
      await gate.setRule('invitations.chat', GateMode.open);
      expect(gate.inbound(chuck, 'inv1.invitations.chat'),
          GateVerdict.quarantined);
    });

    test(
        'when an atSign recorded there sends a namespace-less exchange on the'
        ' short list, then it is admitted', () {
      expect(gate.inbound(bob, 'shared_key', onShortList: true),
          GateVerdict.admitted);
    });

    test(
        'when an atSign recorded only beneath a rule sends a namespace-less'
        ' exchange on the short list, then it is not accepted', () async {
      await gate.setRule('sshnp', GateMode.closed);
      await gate.admit('device.sshnp', dave);
      expect(gate.inbound(dave, 'shared_key', onShortList: true),
          GateVerdict.notAccepted);
    });
  });

  group('Given admissions recorded beneath a closed rule', () {
    for (final GateDefault defaultMode in GateDefault.values) {
      test(
          'when the default is ${defaultMode.name} and an atSign recorded'
          ' beneath reaches it, then the rule decides', () async {
        final Gatekeeper gate = Gatekeeper(defaultMode: defaultMode);
        await gate.setRule('chat', GateMode.closed, admit: bob);
        await gate.admit('invitations.chat', dave);
        expect(gate.inbound(dave, 'inv1.invitations.chat'),
            GateVerdict.notAccepted);
        expect(gate.inbound(chuck, 'inv1.invitations.chat'),
            GateVerdict.notAccepted);
        expect(gate.inbound(bob, 'inv1.invitations.chat'),
            GateVerdict.admitted);
      });
    }
  });

  group('Given a rule to remove', () {
    late Gatekeeper gate;
    setUp(() async {
      gate = Gatekeeper(defaultMode: GateDefault.closed);
      await gate.setRule('chat', GateMode.open,
          setting: GateSetting.limit, value: 3, admit: bob);
      await gate.deny('chat', chuck);
    });

    test(
        'when it is removed, then its admitted set stays recorded and its'
        ' denied set and settings go', () async {
      await gate.removeRule('chat');
      final GateRule rule = gate.ruleFor('chat')!;
      expect(rule.mode, isNull);
      expect(rule.admitted, {bob});
      expect(rule.denied, isEmpty);
      expect(rule.settings, isEmpty);
      expect(gate.inbound(bob, 'msg.chat'), GateVerdict.admitted);
      expect(gate.inbound(chuck, 'msg.chat'), GateVerdict.notAccepted);
    });

    test('when a rule admitting nobody is removed, then nothing is recorded',
        () async {
      await gate.setRule('photos', GateMode.closed);
      await gate.removeRule('photos');
      expect(gate.ruleFor('photos'), isNull);
      expect(gate.namespaces, ['chat']);
    });

    test('when a namespace with no rule has its rule removed, then it is as'
        ' it was', () async {
      await gate.admit('sshnp', bob);
      await gate.removeRule('sshnp');
      await gate.removeRule('photos');
      expect(gate.ruleFor('sshnp')!.admitted, {bob});
      expect(gate.ruleFor('photos'), isNull);
    });

    test('when an open rule is removed, then it no longer counts as open',
        () async {
      final Gatekeeper capped =
          Gatekeeper(limits: const GateLimits(maxOpenNamespaces: 1));
      await capped.setRule('chat', GateMode.open);
      await capped.removeRule('chat');
      await capped.setRule('photos', GateMode.open);
      expect(capped.ruleFor('photos')!.mode, GateMode.open);
    });
  });

  group('Given a gate to check', () {
    test(
        'when an atSign admitted atSign-wide is checked in an open namespace,'
        ' then it answers admitted', () async {
      final Gatekeeper gate = Gatekeeper(defaultMode: GateDefault.closed);
      await gate.setRule('photos', GateMode.open);
      await gate.admit(Gatekeeper.everyNamespace, bob);
      expect(gate.check('photos', bob), GateVerdict.admitted);
      expect(gate.check('photos', chuck), GateVerdict.quarantined);
      expect(gate.check('group.photos', chuck), GateVerdict.quarantined);
      expect(gate.check('sshnp', bob), GateVerdict.admitted);
      await gate.setRule('sshnp', GateMode.closed);
      expect(gate.check('sshnp', bob), GateVerdict.notAccepted);
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
        ' argument', () async {
      await expectLater(Gatekeeper().deny(Gatekeeper.everyNamespace, bob),
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

    test(
        "when a setting is returned to the default, then it follows the"
        " operator's", () async {
      await gate.setRule('invitations.chat', GateMode.open,
          setting: GateSetting.limit);
      final GateRule rule = gate.ruleFor('invitations.chat')!;
      expect(rule.settings, isEmpty);
      expect(gate.settingOf(rule, GateSetting.limit), 10);
      final Gatekeeper later = Gatekeeper(
          limits: const GateLimits(defaults: {
        GateSetting.limit: 20,
        GateSetting.window: 24 * 60 * 60,
        GateSetting.size: 15360,
        GateSetting.maxQuarantined: 100,
        GateSetting.maxQuarantinedBytes: 1024 * 1024,
      }));
      expect(later.settingOf(rule, GateSetting.limit), 20);
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

    test(
        'when an atSign at its cap of namespaces with a rule or recorded'
        ' admissions adds another, then it is refused and nothing changes',
        () async {
      final Gatekeeper gate =
          Gatekeeper(limits: const GateLimits(maxNamespaces: 2));
      await gate.setRule('a.chat', GateMode.closed);
      await gate.admit('b.chat', bob);
      await expectLater(gate.admit('c.chat', bob),
          throwsA(isA<IllegalArgumentException>()));
      await expectLater(gate.setRule('c.chat', GateMode.closed),
          throwsA(isA<IllegalArgumentException>()));
      expect(gate.namespaces, ['a.chat', 'b.chat']);
      await gate.setRule('b.chat', GateMode.open);
      await gate.admit('a.chat', dave);
      expect(gate.ruleFor('b.chat')!.admitted, {bob});
    });

    test(
        'when a full set is added to, then it is refused and nothing changes;'
        ' re-adding a member succeeds', () async {
      final Gatekeeper gate = Gatekeeper(
          limits: const GateLimits(
              maxAdmitted: 1, maxDenied: 1, maxAdmittedEverywhere: 1));
      await gate.setRule('chat', GateMode.open, admit: bob);
      await gate.deny('chat', chuck);
      await gate.admit(Gatekeeper.everyNamespace, bob);
      for (final Future<void> Function() change in [
        () => gate.admit('chat', dave),
        () => gate.setRule('chat', GateMode.closed, admit: dave),
        () => gate.admit('chat', chuck),
        () => gate.deny('chat', dave),
        () => gate.deny('chat', bob),
        () => gate.admit(Gatekeeper.everyNamespace, dave),
      ]) {
        await expectLater(change(), throwsA(isA<IllegalArgumentException>()));
      }
      expect(gate.ruleFor('chat')!.admitted, {bob});
      expect(gate.ruleFor('chat')!.denied, {chuck});
      expect(gate.ruleFor('chat')!.mode, GateMode.open);
      expect(gate.admittedEverywhere, {bob});
      await gate.admit('chat', bob);
      await gate.deny('chat', chuck);
      await gate.admit(Gatekeeper.everyNamespace, bob);
    });
  });

  group('Given a gate to show', () {
    test('when a namespace has no rule, then it shows its mode as none, the'
        ' default and the admissions recorded there', () async {
      final Gatekeeper gate = Gatekeeper(defaultMode: GateDefault.closed);
      expect(gate.show('photos'), {
        'namespace': 'photos',
        'mode': 'none',
        'default': 'closed',
        'admitted': <String>[],
      });
      await gate.admit('photos', dave);
      await gate.admit('photos', bob);
      expect(gate.show('photos'), {
        'namespace': 'photos',
        'mode': 'none',
        'default': 'closed',
        'admitted': ['@bob', '@dave'],
      });
    });

    test(
        'when a namespace is closed, then it shows its settings and both its'
        ' sets', () async {
      final Gatekeeper gate = Gatekeeper();
      await gate.setRule('photos', GateMode.open,
          setting: GateSetting.limit, value: 3);
      await gate.admit('photos', bob);
      await gate.deny('photos', chuck);
      await gate.setRule('photos', GateMode.closed);
      expect(gate.show('photos'), {
        'namespace': 'photos',
        'mode': 'closed',
        'settings': {
          'limit': 3,
          'window': 86400,
          'size': 15360,
          'maxQuarantined': 100,
          'maxQuarantinedBytes': 1048576,
        },
        'admitted': ['@bob'],
        'denied': ['@chuck'],
      });
    });

    test(
        'when a namespace a broader rule decides is shown, then it names that'
        ' namespace', () async {
      final Gatekeeper gate = Gatekeeper(defaultMode: GateDefault.closed);
      await gate.setRule('chat', GateMode.closed);
      expect(gate.show('invitations.chat'), {
        'namespace': 'invitations.chat',
        'mode': 'none',
        'default': 'closed',
        'admitted': <String>[],
        'governedBy': 'chat',
      });
      await gate.admit('invitations.chat', dave);
      expect(gate.show('invitations.chat')['governedBy'], 'chat');
      expect(gate.show('chat').containsKey('governedBy'), isFalse);
      expect(gate.show('photos').containsKey('governedBy'), isFalse);
    });

    test('when the atSign-wide set is shown, then it shows its members sorted',
        () async {
      final Gatekeeper gate = Gatekeeper();
      await gate.admit(Gatekeeper.everyNamespace, dave);
      await gate.admit(Gatekeeper.everyNamespace, bob);
      expect(gate.show(Gatekeeper.everyNamespace), {
        'namespace': '*',
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

  group('Given each kind of refused change', () {
    // NOTE these messages are a wire contract: a client tells the AT0022
    // refusals apart by them (design section 5.2).
    Future<String> refusal(Future<void> Function() change) async {
      try {
        await change();
      } on IllegalArgumentException catch (e) {
        return e.message;
      }
      fail('the change was not refused');
    }

    test('when it is refused, then its message is the one pinned for it',
        () async {
      final Gatekeeper gate = Gatekeeper(
          limits: const GateLimits(
              maxOpenNamespaces: 1,
              maxNamespaces: 2,
              maxAdmitted: 1,
              maxDenied: 1,
              maxAdmittedEverywhere: 1));
      await gate.setRule('chat', GateMode.open, admit: bob);
      await gate.deny('chat', chuck);
      await gate.admit(Gatekeeper.everyNamespace, bob);
      await gate.setRule('sshnp', GateMode.closed);
      expect(
          await refusal(() => gate.setRule('chat', GateMode.open,
              setting: GateSetting.limit, value: 101)),
          'limit may be at most 100 on this atServer');
      expect(
          await refusal(() => gate.setRule('chat', GateMode.open,
              setting: GateSetting.window, value: 3599)),
          'window must be at least 3600 on this atServer');
      expect(await refusal(() => gate.setRule('sshnp', GateMode.open)),
          'This atSign already has 1 open namespaces, the most it may have');
      expect(
          await refusal(() => gate.admit('photos', dave)),
          'This atSign already has 2 namespaces with a rule or recorded'
          ' admissions, the most it may have');
      expect(await refusal(() => gate.admit('chat', dave)),
          'chat already admits 1 atSigns, the most it may');
      expect(await refusal(() => gate.deny('chat', dave)),
          'chat already denies 1 atSigns, the most it may');
      expect(await refusal(() => gate.admit(Gatekeeper.everyNamespace, dave)),
          'The atSign-wide admitted set already holds 1 atSigns, the most it'
          ' may');
      expect(await refusal(() => gate.deny('sshnp', dave)),
          'Only an open namespace denies; sshnp is not open');
      expect(await refusal(() => gate.deny(Gatekeeper.everyNamespace, dave)),
          'Only an open namespace denies; * is not open');
    });
  });
}
