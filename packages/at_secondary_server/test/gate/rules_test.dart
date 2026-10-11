import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gate_store.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/gate/quarantine.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/gate_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../test_utils.dart';

/// The scenarios of docs/projects/gatekeeper/features/rules.feature that one
/// atServer's gate verb proves, each under its scenario's title.
void main() {
  final Atsign bob = '@bob'.toAtsign();
  final Atsign carol = '@carol'.toAtsign();
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();

  late GateVerbHandler handler;
  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    handler = GateVerbHandler(keyValueStore);
    await gate().setDefault(GateDefault.closed);
  });

  tearDown(() async => await verbTestsTearDown());

  void asCram() => inboundConnection.metadata
    ..isAuthenticated = true
    ..authType = AuthType.cram
    ..enrollmentId = null;

  Future<void> enrolledWith(Map<String, String> namespaces) async {
    final String enrollmentId = Uuid().v4();
    inboundConnection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..enrollmentId = enrollmentId;
    await keyValueStore.put(
        '$enrollmentId.new.enrollments.__manage$alice',
        AtData()
          ..data = jsonEncode({
            'sessionId': '123',
            'appName': 'gate',
            'deviceName': 'test',
            'namespaces': namespaces,
            'apkamPublicKey': 'testPublicKeyValue',
            'requestType': 'newEnrollment',
            'approval': {'state': 'approved'}
          }));
  }

  Future<void> asRoot() => enrolledWith({'*': 'rw', '__manage': 'rw'});

  Future<String?> answer(String command) async =>
      (await handler.processInternal(command, inboundConnection)).data;

  Future<Exception> refusal(String command) async {
    try {
      await handler.processInternal(command, inboundConnection);
    } on Exception catch (e) {
      return e;
    }
    fail('"$command" was not refused');
  }

  Future<String?> codeOf(String command) async =>
      GlobalExceptionHandler.getInstance().getErrorCode(await refusal(command));

  bool deniedAnywhere(Atsign other) => gate()
      .namespaces
      .any((namespace) => gate().ruleFor(namespace)!.denied.contains(other));

  test('An application sets the rule for a namespace it holds', () async {
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:rule:chat:open'), 'success');
    expect(gate().ruleFor('chat')!.mode, GateMode.open);
  });

  test('An application denies an atSign in a namespace it holds', () async {
    await enrolledWith({'chat': 'rw'});
    await gate().setRule('chat', GateMode.open);
    expect(gate().check('chat', chuck), GateVerdict.quarantined);
    expect(await answer('gate:deny:chat:@chuck'), 'success');
    expect(gate().ruleFor('chat')!.denied, {chuck});
  });

  test('An application admits an atSign in a namespace it holds', () async {
    await enrolledWith({'chat': 'rw'});
    await gate().setRule('chat', GateMode.open);
    expect(gate().check('chat', chuck), GateVerdict.quarantined);
    expect(await answer('gate:admit:chat:@chuck'), 'success');
    expect(gate().ruleFor('chat')!.admitted, {chuck});
  });

  test('Holding a namespace covers the namespaces beneath it', () async {
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:rule:invitations.chat:open'), 'success');
    expect(gate().ruleFor('invitations.chat')!.mode, GateMode.open);
  });

  group('An application may not change a gate it does not hold', () {
    for (final (Map<String, String> enrolled, String command) in [
      ({'chat': 'rw'}, 'gate:admit:photos:@dave'),
      ({'invitations.chat': 'rw'}, 'gate:rule:chat:open'),
      ({'chat': 'r'}, 'gate:admit:chat:@dave'),
      ({'chat': 'r'}, 'gate:rule:chat:none'),
    ]) {
      test('$enrolled, $command', () async {
        await gate().setRule('chat', GateMode.closed);
        await enrolledWith(enrolled);
        expect(await codeOf(command), 'AT0009');
        expect(gate().ruleFor('chat')!.mode, GateMode.closed);
        expect(gate().ruleFor('chat')!.admitted, isEmpty);
        expect(gate().ruleFor('photos'), isNull);
      });
    }
  });

  test("Reading a namespace's gate takes read access to it", () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await enrolledWith({'chat': 'r'});
    expect(await answer('gate:show:chat'), jsonEncode(gate().show('chat')));
  });

  test('A closed namespace answers its settings and both its sets', () async {
    await gate().setRule('photos', GateMode.open,
        setting: GateSetting.limit, value: 3, admit: bob);
    await gate().deny('photos', chuck);
    await enrolledWith({'photos': 'rw'});
    await answer('gate:rule:photos:closed');
    expect(
        await answer('gate:show:photos'),
        '{"namespace":"photos","mode":"closed","settings":{"limit":3,'
        '"window":86400,"size":15360,"maxQuarantined":100,'
        '"maxQuarantinedBytes":1048576},"admitted":["@bob"],'
        '"denied":["@chuck"]}');
  });

  test(
      'A namespace without a rule answers the default and the admissions'
      ' recorded there', () async {
    await gate().admit('chat', bob);
    await enrolledWith({'chat': 'r'});
    expect(await answer('gate:show:chat'),
        '{"namespace":"chat","mode":"none","default":"closed","admitted":["@bob"]}');
  });

  test('Checking an atSign takes read access to the namespace', () async {
    await gate().setRule('chat', GateMode.open);
    await gate().deny('chat', chuck);
    await enrolledWith({'chat': 'r'});
    expect(await answer('gate:check:chat:@chuck'),
        '{"namespace":"chat","atSign":"@chuck","verdict":"notAccepted"}');
  });

  test('A check answers for the atSign-wide admitted set without showing it',
      () async {
    await gate().setRule('photos', GateMode.open);
    await gate().admit(Gatekeeper.everyNamespace, bob);
    await enrolledWith({'photos': 'r'});
    expect(await answer('gate:check:photos:@bob'),
        '{"namespace":"photos","atSign":"@bob","verdict":"admitted"}');
  });

  test('A namespace that a broader rule decides names it', () async {
    await gate().setRule('chat', GateMode.closed, admit: carol);
    await enrolledWith({'invitations.chat': 'r'});
    expect(
        await answer('gate:show:invitations.chat'),
        '{"namespace":"invitations.chat","mode":"none","default":"closed",'
        '"admitted":[],"governedBy":"chat"}');
  });

  group("A check answers an atSign's standing, and nothing else", () {
    Future<void> checks(String namespace, Atsign atSign, String verdict) async {
      await asRoot();
      expect(await answer('gate:check:$namespace:$atSign'),
          '{"namespace":"$namespace","atSign":"$atSign","verdict":"$verdict"}');
    }

    test('namespace "photos" on @alice\'s atServer is open', () async {
      await gate().setRule('photos', GateMode.open);
      await checks('photos', dave, 'quarantined');
    });

    test(
        '@alice\'s atSign has the ungated default, and no rule covers'
        ' "photos"', () async {
      await gate().setDefault(GateDefault.ungated);
      await checks('photos', dave, 'admitted');
    });

    test(
        'namespace "chat" has no rule, with @bob admitted, and no rule covers'
        ' "group.chat"', () async {
      await gate().admit('chat', bob);
      await checks('group.chat', bob, 'admitted');
    });

    test(
        'namespace "chat" on @alice\'s atServer is closed, admitting only'
        ' @bob', () async {
      await gate().setRule('chat', GateMode.closed, admit: bob);
      await checks('chat', alice, 'admitted');
    });

    test('namespace "photos" is open, and @chuck is on @alice\'s blocklist',
        () async {
      await gate().setRule('photos', GateMode.open);
      asCram();
      await ConfigVerbHandler(keyValueStore, commitLog: atCommitLog)
          .processInternal('config:block:add:@chuck', inboundConnection);
      expect(await keyValueStore.exists('private:blocklist$alice'), isTrue);
      await checks('photos', chuck, 'quarantined');
    });

    test(
        '@chuck is quarantined in open "invitations.chat", at its limit of'
        ' exchanges in the window', () async {
      await gate().setRule('invitations.chat', GateMode.open);
      final Atsign chuck = '@chuck'.toAtsign();
      for (int i = 0; i < 10; i++) {
        await gate().count(chuck, 'x.invitations.chat');
      }
      await expectLater(gate().count(chuck, 'x.invitations.chat'),
          throwsA(isA<QuarantineLimitException>()));
      await checks('invitations.chat', chuck, 'quarantined');
    });
  });

  test('Any enrollment reads the default', () async {
    await enrolledWith({'chat': 'r'});
    expect(await answer('gate:default'), 'closed');
  });

  test('A namespace is lower-cased', () async {
    await asRoot();
    expect(await answer('gate:rule:Chat:closed:admit:@bob'), 'success');
    expect(gate().ruleFor('chat')!.mode, GateMode.closed);
    expect(gate().ruleFor('chat')!.admitted, {bob});
    expect(gate().namespaces, ['chat']);
  });

  group('A namespace with an empty label does not parse', () {
    for (final String command in [
      'gate:rule:.chat:open',
      'gate:admit:a..chat:@bob',
      'gate:show:chat.',
      'gate:check:.chat:@bob',
    ]) {
      test(command, () async {
        await asRoot();
        expect(await codeOf(command), 'AT0003');
        expect(gate().namespaces, isEmpty);
      });
    }
  });

  test('A root connection reads the atSign-wide admitted set', () async {
    await gate().admit(Gatekeeper.everyNamespace, dave);
    await gate().admit(Gatekeeper.everyNamespace, bob);
    await asRoot();
    expect(await answer('gate:show:*'),
        '{"namespace":"*","admitted":["@bob","@dave"]}');
  });

  test(
      'A root connection lists every namespace with a rule or recorded'
      ' admissions', () async {
    await gate().setRule('chat', GateMode.closed);
    await gate().setRule('photos', GateMode.open);
    await gate().admit('sshnp', bob);
    await asRoot();
    expect(await answer('gate:list'), '["chat","photos","sshnp"]');
  });

  test('Any other connection lists the namespaces its enrollment holds',
      () async {
    await gate().setRule('chat', GateMode.closed);
    await gate().setRule('invitations.chat', GateMode.open);
    await gate().setRule('photos', GateMode.open);
    await enrolledWith({'chat': 'r'});
    expect(await answer('gate:list'), '["chat","invitations.chat"]');
  });

  group('An application may not read a gate it does not hold', () {
    for (final (Map<String, String> enrolled, String command) in [
      ({'chat': 'rw'}, 'gate:show:photos'),
      ({'chat': 'rw'}, 'gate:check:photos:@bob'),
      ({'*': 'rw'}, 'gate:show:*'),
    ]) {
      test('$enrolled, $command', () async {
        await enrolledWith(enrolled);
        expect(await codeOf(command), 'AT0009');
      });
    }
  });

  test(
      'An enrollment holding "*" without "__manage" may not change the'
      ' atSign-wide admitted set', () async {
    await enrolledWith({'*': 'rw'});
    expect(await codeOf('gate:admit:*:@dave'), 'AT0009');
    expect(gate().admittedEverywhere, isEmpty);
  });

  test('A root enrollment changes the atSign-wide admitted set', () async {
    await asRoot();
    expect(await answer('gate:admit:*:@dave'), 'success');
    expect(gate().admittedEverywhere, {dave});
  });

  test('An application records an admission in a namespace without a rule',
      () async {
    await gate().setDefault(GateDefault.ungated);
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:admit:chat:@bob'), 'success');
    expect(gate().ruleFor('chat')!.admitted, {bob});
    expect(gate().ruleFor('chat')!.mode, isNull);
  });

  test('A rule set on a namespace starts from the admissions recorded there',
      () async {
    await gate().admit('chat', bob);
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:rule:chat:open'), 'success');
    expect(gate().ruleFor('chat')!.mode, GateMode.open);
    expect(gate().ruleFor('chat')!.admitted, {bob});
  });

  test('An application removes the rule for a namespace it holds', () async {
    await gate().setRule('chat', GateMode.open, admit: bob);
    await gate().deny('chat', chuck);
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:rule:chat:none'), 'success');
    expect(gate().ruleFor('chat')!.mode, isNull);
    expect(gate().ruleFor('chat')!.admitted, {bob});
    expect(deniedAnywhere(chuck), isFalse);
  });

  test(
      'Removing the last admission recorded without a rule leaves nothing to'
      ' list', () async {
    await gate().admit('chat', bob);
    await asRoot();
    expect(await answer('gate:remove:chat:@bob'), 'success');
    expect(jsonDecode((await answer('gate:list'))!), isNot(contains('chat')));
  });

  test('Only a root connection switches the default', () async {
    await gate().setDefault(GateDefault.ungated);
    await enrolledWith({'chat': 'rw'});
    expect(await codeOf('gate:default:closed'), 'AT0009');
    expect(gate().defaultMode, GateDefault.ungated);
  });

  test('A root connection switches the default', () async {
    await gate().setDefault(GateDefault.ungated);
    await asRoot();
    expect(await answer('gate:default:closed'), 'success');
    expect(gate().defaultMode, GateDefault.closed);
  });

  test('Setting a rule admits only the atSigns the application names',
      () async {
    await keyValueStore.put('@bob:status.chat$alice', AtData()..data = 'b');
    await keyValueStore.put('@carol:status.chat$alice', AtData()..data = 'c');
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:rule:chat:closed:admit:@bob'), 'success');
    expect(gate().check('chat', bob), GateVerdict.admitted);
    expect(gate().check('chat', carol), GateVerdict.notAccepted);
  });

  group('Admitting a denied atSign takes it out of the denied set', () {
    for (final GateMode mode in [GateMode.open, GateMode.closed]) {
      test(mode.name, () async {
        await gate().setRule('photos', GateMode.open);
        await gate().deny('photos', chuck);
        await gate().setRule('photos', mode);
        await enrolledWith({'photos': 'rw'});
        expect(await answer('gate:admit:photos:@chuck'), 'success');
        expect(gate().ruleFor('photos')!.admitted, {chuck});
        expect(deniedAnywhere(chuck), isFalse);
      });
    }
  });

  test("Removing an atSign from a closed namespace's kept denied set",
      () async {
    await gate().setRule('photos', GateMode.open);
    await gate().deny('photos', chuck);
    await gate().setRule('photos', GateMode.closed);
    await enrolledWith({'photos': 'rw'});
    expect(await answer('gate:remove:photos:@chuck'), 'success');
    expect(deniedAnywhere(chuck), isFalse);
  });

  group('Denying in a namespace that is not open is refused', () {
    for (final (String command, String ns) in [
      ('gate:deny:chat:@chuck', 'chat'),
      ('gate:deny:photos:@chuck', 'photos'),
      ('gate:deny:*:@chuck', '*'),
    ]) {
      test(command, () async {
        await gate().setRule('chat', GateMode.closed, admit: bob);
        await asRoot();
        final Exception e = await refusal(command);
        expect(GlobalExceptionHandler.getInstance().getErrorCode(e), 'AT0022');
        expect((e as AtException).message,
            'Only an open namespace denies; $ns is not open');
        expect(deniedAnywhere(chuck), isFalse);
      });
    }
  });

  test('Re-issuing a rule changes only the setting it names', () async {
    await gate().setRule('invitations.chat', GateMode.open,
        setting: GateSetting.limit, value: 3, admit: bob);
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:rule:invitations.chat:open:window:7200'),
        'success');
    final GateRule rule = gate().ruleFor('invitations.chat')!;
    expect(gate().settingOf(rule, GateSetting.limit), 3);
    expect(gate().settingOf(rule, GateSetting.window), 7200);
    expect(rule.admitted, {bob});
  });

  test("A setting returned to the default follows the operator's", () async {
    expect(gate().limits.defaults[GateSetting.limit], 10);
    await gate().setRule('invitations.chat', GateMode.open,
        setting: GateSetting.limit, value: 3);
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:rule:invitations.chat:open:limit:default'),
        'success');
    expect(gate().settingOf(gate().ruleFor('invitations.chat')!,
        GateSetting.limit), 10);
    final Gatekeeper restarted = await Gatekeeper.load(
        GateStore(keyValueStore, alice),
        limits: GateLimits(
            defaults: {...gate().limits.defaults, GateSetting.limit: 20}));
    expect(
        restarted.settingOf(
            restarted.ruleFor('invitations.chat')!, GateSetting.limit),
        20);
  });

  test("Opening a namespace beyond the atSign's cap is refused", () async {
    expect(gate().limits.maxOpenNamespaces, 50);
    for (int i = 1; i <= 50; i++) {
      await gate().setRule('x$i.chat', GateMode.open);
    }
    await enrolledWith({'chat': 'rw'});
    final Exception e = await refusal('gate:rule:x51.chat:open');
    expect(GlobalExceptionHandler.getInstance().getErrorCode(e), 'AT0022');
    expect((e as AtException).message,
        'This atSign already has 50 open namespaces, the most it may have');
    expect(gate().ruleFor('x51.chat'), isNull);
  });

  group("A set or a count of namespaces beyond the operator's cap is refused",
      () {
    Set<Atsign> atSigns(int n) => {for (int i = 0; i < n; i++) '@a$i'.toAtsign()};

    Future<void> preload(GateRecords records) async {
      AtSecondaryServerImpl.getInstance().gatekeeper =
          await Gatekeeper.load(_PreloadedStore(records));
      await asRoot();
    }

    Future<void> refusedWith(String command, String message) async {
      final String before = jsonEncode({
        for (final String n in gate().namespaces) n: gate().show(n),
        '*': gate().show(Gatekeeper.everyNamespace),
      });
      final Exception e = await refusal(command);
      expect(GlobalExceptionHandler.getInstance().getErrorCode(e), 'AT0022');
      expect((e as AtException).message, message);
      expect(
          jsonEncode({
            for (final String n in gate().namespaces) n: gate().show(n),
            '*': gate().show(Gatekeeper.everyNamespace),
          }),
          before);
    }

    test('10,000 admitted atSigns in a namespace', () async {
      await preload(GateRecords(GateDefault.closed,
          {'chat': GateRule(GateMode.closed, admitted: atSigns(10000))}, {}));
      await refusedWith('gate:admit:chat:@dave',
          'chat already admits 10000 atSigns, the most it may');
    });

    test('10,000 denied atSigns in a namespace', () async {
      await preload(GateRecords(GateDefault.closed,
          {'photos': GateRule(GateMode.open, denied: atSigns(10000))}, {}));
      await refusedWith('gate:deny:photos:@dave',
          'photos already denies 10000 atSigns, the most it may');
    });

    test('10,000 atSigns in the atSign-wide admitted set', () async {
      await preload(GateRecords(GateDefault.closed, {}, atSigns(10000)));
      await refusedWith('gate:admit:*:@dave',
          'The atSign-wide admitted set already holds 10000 atSigns, the most'
          ' it may');
    });

    for (final String command in [
      'gate:admit:x1001.chat:@dave',
      'gate:rule:x1001.chat:closed',
    ]) {
      test('1,000 namespaces with a rule or recorded admissions, $command',
          () async {
        await preload(GateRecords(GateDefault.closed, {
          for (int i = 1; i <= 1000; i++)
            'x$i.chat': i.isEven
                ? GateRule(GateMode.closed)
                : GateRule(null, admitted: {bob})
        }, {}));
        await refusedWith(
            command,
            'This atSign already has 1000 namespaces with a rule or recorded'
            ' admissions, the most it may have');
      });
    }
  });

  test('Admitting an atSign already admitted in a full namespace succeeds',
      () async {
    AtSecondaryServerImpl.getInstance().gatekeeper = await Gatekeeper.load(
        _PreloadedStore(GateRecords(GateDefault.closed, {
      'chat': GateRule(GateMode.closed, admitted: {
        bob,
        for (int i = 1; i < 10000; i++) '@a$i'.toAtsign(),
      })
    }, {})));
    expect(gate().ruleFor('chat')!.admitted.length, 10000);
    await enrolledWith({'chat': 'rw'});
    expect(await answer('gate:admit:chat:@bob'), 'success');
  });

  test('Two admissions in one namespace at once both take effect', () async {
    await gate().setRule('chat', GateMode.closed);
    await enrolledWith({'chat': 'rw'});
    await Future.wait(
        [answer('gate:admit:chat:@bob'), answer('gate:admit:chat:@dave')]);
    expect(gate().ruleFor('chat')!.admitted, {bob, dave});
    expect((await GateStore(keyValueStore, alice).load()).rules['chat']!.admitted,
        {bob, dave});
  });

  group('A gate record cannot be changed except through the gate verb', () {
    for (final String command in [
      'keys:delete:keyName:local:chat.rule.gate@alice',
      'notify:update:@alice:local:chat.rule.gate@alice:{}',
    ]) {
      test(command, () async {
        await gate().setRule('chat', GateMode.closed, admit: bob);
        await asRoot();
        final AbstractVerbHandler verb = command.startsWith('keys:')
            ? KeysVerbHandler(keyValueStore, enMgr, alice)
            : NotifyVerbHandler(keyValueStore, notificationManager);
        Exception? refused;
        try {
          await verb.processInternal(command, inboundConnection);
        } on Exception catch (e) {
          refused = e;
        }
        expect(refused, isNotNull, reason: '"$command" was not refused');
        expect(GlobalExceptionHandler.getInstance().getErrorCode(refused!),
            'AT0009');
        for (final Gatekeeper after in [
          gate(),
          await Gatekeeper.load(GateStore(keyValueStore, alice)),
        ]) {
          expect(after.ruleFor('chat')!.mode, GateMode.closed);
          expect(after.ruleFor('chat')!.admitted, {bob});
        }
      });
    }
  });

  test("Another atSign may not change @alice's gate", () async {
    inboundConnection.metadata
      ..isAuthenticated = false
      ..isPolAuthenticated = true
      ..fromAtSign = chuck;
    expect(await codeOf('gate:admit:chat:@chuck'), 'AT0401');
    expect(gate().ruleFor('chat'), isNull);
  });
}

/// A store holding [records] from the start, whose writes succeed and keep
/// nothing.
class _PreloadedStore extends Fake implements GateStore {
  final GateRecords records;

  _PreloadedStore(this.records);

  @override
  Future<GateRecords> load() async => records;

  @override
  Future<void> putDefault(GateDefault mode) async {}

  @override
  Future<void> putRule(String namespace, GateRule rule) async {}

  @override
  Future<void> deleteRule(String namespace) async {}

  @override
  Future<void> putQuarantine(
      String namespace, Map<Atsign, QuarantineEntry> entries) async {}

  @override
  Future<void> deleteQuarantine(String namespace) async {}

  @override
  Future<void> putAdmittedEverywhere(Set<Atsign> atSigns) async {}
}
