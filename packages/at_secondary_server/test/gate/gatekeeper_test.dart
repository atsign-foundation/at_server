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
}
