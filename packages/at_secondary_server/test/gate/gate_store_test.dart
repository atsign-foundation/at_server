import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/gate/gate_store.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/gate/quarantine.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The gate's `local:` records, read back from each keystore backend.
void main() {
  final Atsign bob = '@bob'.toAtsign();
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();

  for (final AtPersistenceBackendId backend in [
    AtPersistenceBackendId.hive,
    AtPersistenceBackendId.sqlite
  ]) {
    group('Given a gate kept in the ${backend.name} keystore', () {
      late GateStore store;
      setUp(() async {
        await verbTestsSetUp(backend: backend);
        store = GateStore(keyValueStore, alice);
      });
      tearDown(() async => await verbTestsTearDown());

      test('when nothing was written, then it reads back no default, no rule'
          ' and nobody admitted everywhere', () async {
        final GateRecords records = await store.load();
        expect(records.defaultMode, isNull);
        expect(records.rules, isEmpty);
        expect(records.admittedEverywhere, isEmpty);
      });

      test('when it is read back, then its default, rules and atSign-wide set'
          ' are as written', () async {
        await store.putDefault(GateDefault.closed);
        await store.putRule(
            'chat', GateRule(GateMode.closed, admitted: {bob}));
        await store.putRule(
            'invitations.chat',
            GateRule(GateMode.open,
                admitted: {dave},
                denied: {chuck},
                settings: {GateSetting.limit: 3}));
        await store.putAdmittedEverywhere({dave});

        final GateRecords records = await store.load();
        expect(records.defaultMode, GateDefault.closed);
        expect(records.rules.keys.toSet(), {'chat', 'invitations.chat'});
        expect(records.rules['chat']!.mode, GateMode.closed);
        expect(records.rules['chat']!.admitted, {bob});
        final GateRule open = records.rules['invitations.chat']!;
        expect(open.mode, GateMode.open);
        expect(open.admitted, {dave});
        expect(open.denied, {chuck});
        expect(open.settings, {GateSetting.limit: 3});
        expect(records.admittedEverywhere, {dave});
      });

      test('when its records are written, then none enters the commit log',
          () async {
        final int? before = atCommitLog.lastCommittedSequenceNumber();
        await store.putDefault(GateDefault.closed);
        await store.putRule('chat', GateRule(GateMode.closed, admitted: {bob}));
        await store.putAdmittedEverywhere({dave});
        expect(atCommitLog.lastCommittedSequenceNumber(), before);
      });

      test('when a rule is rewritten, then it reads back as rewritten',
          () async {
        await store.putRule('chat', GateRule(GateMode.closed, admitted: {bob}));
        await store.putRule('chat',
            GateRule(GateMode.open, admitted: {bob}, denied: {chuck}));
        final GateRule rule = (await store.load()).rules['chat']!;
        expect(rule.mode, GateMode.open);
        expect(rule.denied, {chuck});
      });

      test('when a gate is changed and loaded again, then it is as changed',
          () async {
        final Gatekeeper gate = await Gatekeeper.load(store);
        await gate.setDefault(GateDefault.closed);
        await gate.setRule('chat', GateMode.closed, admit: bob);
        await gate.setRule('invitations.chat', GateMode.open,
            setting: GateSetting.limit, value: 3);
        await gate.deny('invitations.chat', chuck);
        await gate.admit(Gatekeeper.everyNamespace, dave);

        final Gatekeeper again = await Gatekeeper.load(GateStore(keyValueStore, alice));
        expect(again.defaultMode, GateDefault.closed);
        expect(again.show('chat'), gate.show('chat'));
        expect(again.show('invitations.chat'), gate.show('invitations.chat'));
        expect(again.admittedEverywhere, {dave});
        expect(again.inbound(chuck, 'inv.invitations.chat'),
            GateVerdict.notAccepted);
      });

      test(
          'when admissions are recorded without a rule and then removed, then'
          ' they read back and then the record is gone', () async {
        final Gatekeeper gate = await Gatekeeper.load(store);
        await gate.admit('chat', bob);
        GateRecords records = await store.load();
        expect(records.rules['chat']!.mode, isNull);
        expect(records.rules['chat']!.admitted, {bob});
        await gate.remove('chat', bob);
        records = await store.load();
        expect(records.rules, isEmpty);
        expect(await keyValueStore.exists('local:chat.rule.gate$alice'), isFalse);
      });

      test('when nothing was written, then the gate loads with the starting'
          ' default', () async {
        final Gatekeeper gate = await Gatekeeper.load(store,
            startingDefault: GateDefault.closed);
        expect(gate.defaultMode, GateDefault.closed);
      });
    });
  }

  group('Given a store that fails to write', () {
    test('when the gate is changed, then the change is refused and the gate is'
        ' as it was', () async {
      final _FailingStore store = _FailingStore();
      final Gatekeeper gate = Gatekeeper(store: store);
      await expectLater(gate.setDefault(GateDefault.closed), throwsStateError);
      await expectLater(
          gate.setRule('chat', GateMode.closed, admit: bob), throwsStateError);
      await expectLater(
          gate.admit(Gatekeeper.everyNamespace, dave), throwsStateError);
      expect(gate.defaultMode, GateDefault.ungated);
      expect(gate.ruleFor('chat'), isNull);
      expect(gate.admittedEverywhere, isEmpty);

      store.failing = false;
      await gate.setRule('chat', GateMode.open);
      store.failing = true;
      await expectLater(gate.admit('chat', bob), throwsStateError);
      await expectLater(gate.deny('chat', chuck), throwsStateError);
      expect(gate.ruleFor('chat')!.admitted, isEmpty);
      expect(gate.ruleFor('chat')!.denied, isEmpty);

      store.failing = false;
      await gate.admit('photos', bob);
      store.failing = true;
      await expectLater(gate.remove('photos', bob), throwsStateError);
      expect(gate.ruleFor('photos')!.admitted, {bob});
      await gate.remove('sshnp', bob);
    });
  });
}

/// A store whose writes fail while [failing] is set.
class _FailingStore extends Fake implements GateStore {
  bool failing = true;

  Future<void> _write() async {
    if (failing) {
      throw StateError('the keystore refused the write');
    }
  }

  @override
  Future<void> putDefault(GateDefault mode) => _write();

  @override
  Future<void> putRule(String namespace, GateRule rule) => _write();

  @override
  Future<void> deleteRule(String namespace) => _write();

  @override
  Future<void> putQuarantine(
          String namespace, Map<Atsign, QuarantineEntry> entries) =>
      _write();

  @override
  Future<void> deleteQuarantine(String namespace) => _write();

  @override
  Future<void> putAdmittedEverywhere(Set<Atsign> atSigns) => _write();
}
