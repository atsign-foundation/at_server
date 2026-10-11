import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gate_store.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/gate_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:clock/clock.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The scenarios of docs/projects/gatekeeper/features/quarantine.feature
/// whose observable is one atServer's answer and its gate, each under its
/// scenario's title.
void main() {
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();
  final Atsign erin = '@erin'.toAtsign();
  final Atsign frank = '@frank'.toAtsign();
  const String inv = 'invitations.chat';

  late NotifyVerbHandler notifyHandler;
  late LookupVerbHandler lookupHandler;
  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    notifyHandler = NotifyVerbHandler(keyValueStore, notificationManager);
    lookupHandler = LookupVerbHandler(
        keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
        accessLog: atAccessLog);
    await gate().setDefault(GateDefault.closed);
    await gate().setRule(inv, GateMode.open);
  });

  tearDown(() async => await verbTestsTearDown());

  Future<String?> sends(Atsign other, String command) async {
    inboundConnection.metadata
      ..isAuthenticated = false
      ..isPolAuthenticated = true
      ..fromAtSign = other;
    final handler =
        command.startsWith('notify:') ? notifyHandler : lookupHandler;
    return (await handler.processInternal(command, inboundConnection)).data;
  }

  Future<String?> refusalCode(Atsign other, String command) async {
    Exception? refused;
    try {
      await sends(other, command);
    } on Exception catch (e) {
      refused = e;
    }
    expect(refused, isNotNull, reason: '"$command" was not refused');
    return GlobalExceptionHandler.getInstance().getErrorCode(refused!);
  }

  int counted(Atsign other, [String namespace = inv]) =>
      gate().quarantinedIn(namespace)[other]?.counted.length ?? 0;

  Future<void> countedAlready(Atsign other, int times,
      {String namespace = inv, int bytes = 100}) async {
    for (int i = 0; i < times; i++) {
      await gate().count(other, 'x.$namespace', bytes: bytes);
    }
  }

  /// A notify command from [other] in invitations.chat of exactly [size]
  /// bytes.
  String commandOf(int size, Atsign other, {String id = 'sized'}) {
    final String head = 'notify:id:$id:@alice:big.$inv$other:';
    return head + 'x' * (size - utf8.encode(head).length);
  }

  test(
      'An accepted notification quarantines an atSign seen for the first time',
      () async {
    expect(await sends(dave, 'notify:id:1:@alice:inv1.invitations.chat@dave'),
        'data:success');
    expect(counted(dave), 1);
  });

  test('A lookup quarantines an atSign seen for the first time', () async {
    await keyValueStore.put(
        '@dave:profile.invitations.chat$alice', AtData()..data = 'profile');
    expect(await sends(dave, 'lookup:profile.invitations.chat@alice'),
        'profile');
    expect(counted(dave), 1);
  });

  test(
      'A quarantined atSign may look up a key shared with it, and the lookup'
      ' counts', () async {
    await countedAlready(chuck, 4);
    await keyValueStore.put(
        '@chuck:profile.invitations.chat$alice', AtData()..data = 'profile');
    expect(await sends(chuck, 'lookup:profile.invitations.chat@alice'),
        'profile');
    expect(counted(chuck), 5);
  });

  test('A lookup of a key that is not there counts too', () async {
    await countedAlready(chuck, 4);
    expect(await refusalCode(chuck, 'lookup:nothing.invitations.chat@alice'),
        'AT0015');
    expect(counted(chuck), 5);
  });

  test('The eleventh exchange in a window is refused', () async {
    await countedAlready(chuck, 10);
    expect(
        await refusalCode(
            chuck, 'notify:id:11:@alice:inv11.invitations.chat@chuck'),
        'AT0034');
  });

  test('The window rolls', () async {
    final DateTime t0 = DateTime.now().toUtc();
    await withClock(Clock.fixed(t0.subtract(const Duration(hours: 24, minutes: 1))),
        () => countedAlready(chuck, 1));
    await withClock(Clock.fixed(t0.subtract(const Duration(hours: 1))),
        () => countedAlready(chuck, 9));
    expect(
        await withClock(Clock.fixed(t0),
            () => sends(chuck, 'notify:id:12:@alice:inv12.invitations.chat@chuck')),
        'data:success');
  });

  test('Counting is per namespace', () async {
    await gate().setRule('photos', GateMode.open);
    await countedAlready(chuck, 10);
    expect(await sends(chuck, 'notify:id:13:@alice:pic.photos@chuck'),
        'data:success');
    expect(counted(chuck, 'photos'), 1);
  });

  test('Removing notifications does not free a place', () async {
    for (int i = 1; i <= 10; i++) {
      await sends(chuck, 'notify:id:r$i:@alice:inv$i.invitations.chat@chuck');
    }
    for (int i = 1; i <= 10; i++) {
      await notificationManager.remove('r$i');
    }
    expect(
        await refusalCode(
            chuck, 'notify:id:14:@alice:inv14.invitations.chat@chuck'),
        'AT0034');
  });

  test('A repeated notification id does not count', () async {
    for (int i = 1; i <= 9; i++) {
      await sends(chuck, 'notify:id:$i:@alice:inv$i.invitations.chat@chuck');
    }
    expect(await sends(chuck, 'notify:id:9:@alice:inv9.invitations.chat@chuck'),
        'data:success');
    expect(counted(chuck), 9);
    expect(await notificationManager.isKeyExists('9'), isTrue);
  });

  test('A notification already expired on arrival does not count', () async {
    await countedAlready(chuck, 9);
    final String expired = VerbUtil.formatIso8601Micros(DateTime.now()
        .toUtcMillisecondsPrecision()
        .subtract(const Duration(minutes: 1)));
    expect(
        await sends(chuck,
            'notify:id:ex:eAtn:$expired:@alice:inv.invitations.chat@chuck'),
        'data:success');
    expect(counted(chuck), 9);
  });

  test('A refused notification does not count', () async {
    await countedAlready(chuck, 9);
    expect(await refusalCode(chuck, commandOf(15361, chuck)), 'AT0035');
    expect(counted(chuck), 9);
  });

  test('A notification at the size cap is accepted', () async {
    await countedAlready(chuck, 1);
    expect(await sends(chuck, commandOf(15360, chuck)), 'data:success');
  });

  test('A notification over the size cap is refused', () async {
    await countedAlready(chuck, 1);
    expect(await refusalCode(chuck, commandOf(15361, chuck)), 'AT0035');
    expect(await notificationManager.isKeyExists('sized'), isFalse);

    const String head = 'notify:id:wide:@alice:big.$inv@chuck:';
    final String wide =
        head + '€' * 5000 + 'x' * (15361 - utf8.encode(head).length - 15000);
    expect(utf8.encode(wide).length, 15361);
    expect(wide.length, lessThan(15360));
    expect(await refusalCode(chuck, wide), 'AT0035');
  });

  test('Metadata counts toward the size cap', () async {
    await countedAlready(chuck, 1);
    final String appMetadata = Metadata.encodeAppMetadata(
        AppMetadata(providerId: 'test', additional: {'pad': 'a' * 12000}));
    expect(appMetadata.length, greaterThan(16000));
    expect(
        await refusalCode(
            chuck,
            'notify:id:md:appMetadata:$appMetadata'
            ':@alice:inv.invitations.chat@chuck'),
        'AT0035');
  });

  test('A quarantined notification with ttr creates no cached key', () async {
    await countedAlready(chuck, 1);
    expect(
        await sends(chuck,
            'notify:id:15:update:ttr:60000:@alice:inv15.invitations.chat@chuck:v'),
        'data:success');
    expect(await notificationManager.isKeyExists('15'), isTrue);
    expect(
        await keyValueStore.exists('cached:@alice:inv15.invitations.chat@chuck'),
        isFalse);
  });

  test('A quarantined delete removes no cached key', () async {
    await countedAlready(chuck, 1);
    await keyValueStore.put(
        'cached:@alice:old.invitations.chat@chuck',
        AtData()
          ..data = 'old'
          ..metaData = (AtMetaData()..isCascade = true));
    expect(
        await sends(chuck,
            'notify:id:16:delete:ttr:60000:ccd:true:@alice:old.invitations.chat@chuck'),
        'data:success');
    expect(
        await keyValueStore.exists('cached:@alice:old.invitations.chat@chuck'),
        isTrue);
  });

  test('An ephemeral notification counts', () async {
    await countedAlready(chuck, 9);
    expect(
        await sends(chuck, 'notify:id:17:eph:@alice:inv17.invitations.chat@chuck'),
        'data:success');
    expect(counted(chuck), 10);
  });

  test("A namespace's holders set its count limit", () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.limit, value: 3);
    await countedAlready(chuck, 3);
    expect(
        await refusalCode(
            chuck, 'notify:id:18:@alice:inv18.invitations.chat@chuck'),
        'AT0034');
  });

  test("A namespace's holders set its size cap", () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.size, value: 1024);
    await countedAlready(chuck, 1);
    expect(await refusalCode(chuck, commandOf(1025, chuck)), 'AT0035');
  });

  Future<Exception> settingRefused(String command) async {
    inboundConnection.metadata
      ..isAuthenticated = true
      ..isPolAuthenticated = false
      ..authType = AuthType.cram
      ..enrollmentId = null;
    try {
      await GateVerbHandler(keyValueStore)
          .processInternal(command, inboundConnection);
    } on Exception catch (e) {
      return e;
    }
    fail('"$command" was not refused');
  }

  group("A setting above the operator's ceiling is refused", () {
    for (final (String setting, int ceiling, int value) in [
      ('limit', 100, 101),
      ('size', 65536, 65537),
      ('maxQuarantined', 1000, 1001),
      ('maxQuarantinedBytes', 16777216, 16777217),
    ]) {
      test(setting, () async {
        final Map<String, Object?> before = gate().show(inv);
        final Exception e = await settingRefused(
            'gate:rule:invitations.chat:open:$setting:$value');
        expect(GlobalExceptionHandler.getInstance().getErrorCode(e), 'AT0022');
        expect((e as AtException).message,
            '$setting may be at most $ceiling on this atServer');
        expect(gate().show(inv), before);
      });
    }
  });

  test("A window shorter than the operator's floor is refused", () async {
    final Map<String, Object?> before = gate().show(inv);
    final Exception e =
        await settingRefused('gate:rule:invitations.chat:open:window:3599');
    expect(GlobalExceptionHandler.getInstance().getErrorCode(e), 'AT0022');
    expect((e as AtException).message,
        'window must be at least 3600 on this atServer');
    expect(gate().show(inv), before);
  });

  /// Restarts @alice's atServer with the operator's ceiling for the count
  /// limit at [ceiling].
  Future<void> restartedWithLimitCeiling(int ceiling) async =>
      AtSecondaryServerImpl.getInstance().gatekeeper = await Gatekeeper.load(
          GateStore(keyValueStore, alice),
          limits: GateLimits(ceilings: {
            ...const GateLimits().ceilings,
            GateSetting.limit: ceiling,
          }));

  test(
      'A setting above a ceiling the operator has since lowered counts as the'
      ' ceiling', () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.limit, value: 50);
    await restartedWithLimitCeiling(20);
    await countedAlready(chuck, 20);
    expect(
        await refusalCode(
            chuck, 'notify:id:32:@alice:inv32.invitations.chat@chuck'),
        'AT0034');
  });

  test(
      'A setting held at a lowered ceiling is back in force when the ceiling'
      ' is raised again', () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.limit, value: 50);
    await restartedWithLimitCeiling(20);
    await restartedWithLimitCeiling(100);
    await countedAlready(chuck, 20);
    expect(await sends(chuck, 'notify:id:33:@alice:inv33.invitations.chat@chuck'),
        'data:success');
  });

  test(
      'Given a limit of 50, when the ceiling is lowered to 20, then gate:show'
      ' answers 20 and the record keeps 50', () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.limit, value: 50);
    await restartedWithLimitCeiling(20);
    expect((gate().show(inv)['settings'] as Map)['limit'], 20);
    expect(
        (await GateStore(keyValueStore, alice).load())
            .rules[inv]!
            .settings[GateSetting.limit],
        50);
  });

  test('Admitting an atSign ends its counting', () async {
    await countedAlready(chuck, 10);
    await gate().admit(inv, chuck);
    expect(await sends(chuck, 'notify:id:19:@alice:inv19.invitations.chat@chuck'),
        'data:success');
  });

  test('Denying a quarantined atSign refuses it from then on', () async {
    await countedAlready(chuck, 1);
    await gate().deny(inv, chuck);
    expect(
        await refusalCode(
            chuck, 'notify:id:20:@alice:inv20.invitations.chat@chuck'),
        'AT0033');
  });

  test('Closing a namespace ends its quarantine', () async {
    await countedAlready(chuck, 10);
    await gate().setRule(inv, GateMode.closed);
    await gate().setRule(inv, GateMode.open);
    expect(await sends(chuck, 'notify:id:31:@alice:inv31.invitations.chat@chuck'),
        'data:success');
    expect(counted(chuck), 1);
  });

  test(
      'gate:show answers the quarantined atSigns in order of first contact',
      () async {
    final DateTime t0 = DateTime.now().toUtc();
    await withClock(Clock.fixed(t0.subtract(const Duration(minutes: 5))),
        () => countedAlready(erin, 1));
    await withClock(Clock.fixed(t0), () => countedAlready(dave, 1));
    inboundConnection.metadata
      ..isAuthenticated = true
      ..isPolAuthenticated = false
      ..authType = AuthType.cram
      ..enrollmentId = null;
    final Map<String, dynamic> shown = jsonDecode((await GateVerbHandler(
                keyValueStore)
            .processInternal('gate:show:$inv', inboundConnection))
        .data!);
    final List<dynamic> quarantined = shown['quarantined'];
    expect(quarantined.map((e) => e['atSign']), ['@erin', '@dave']);
    for (final dynamic entry in quarantined) {
      expect(entry['firstContact'],
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')));
    }
  });

  test('A full quarantine refuses atSigns seen for the first time', () async {
    for (int i = 0; i < 100; i++) {
      await countedAlready('@a$i'.toAtsign(), 1);
    }
    expect(
        await refusalCode(erin, 'notify:id:23:@alice:inv23.invitations.chat@erin'),
        'AT0034');
    expect(counted(erin), 0);
  });

  test('Quarantined notifications accepted up to the byte bound refuse the next one',
      () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.maxQuarantinedBytes, value: 1000);
    await countedAlready(dave, 1, bytes: 1000);
    await gate().count(chuck, 'profile.$inv');
    expect(counted(chuck), 1);
    expect(
        await refusalCode(
            chuck, 'notify:id:24:@alice:inv24.invitations.chat@chuck'),
        'AT0034');
  });

  test('A quarantined atSign that goes quiet for a window drops back to none',
      () async {
    final DateTime t0 = DateTime.now().toUtc();
    await withClock(Clock.fixed(t0.subtract(const Duration(hours: 24, seconds: 1))),
        () => countedAlready(chuck, 1));
    expect(withClock(Clock.fixed(t0), () => gate().quarantinedIn(inv)),
        isNot(contains(chuck)));
  });

  test('A full quarantine in one namespace leaves another alone', () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.maxQuarantined, value: 1);
    await countedAlready(chuck, 1);
    await gate().setRule('photos', GateMode.open);
    expect(await sends(erin, 'notify:id:25:@alice:pic.photos@erin'),
        'data:success');
  });

  test("A namespace's holders set its bound on quarantined atSigns", () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.maxQuarantined, value: 2);
    await countedAlready(chuck, 1);
    await countedAlready(dave, 1);
    expect(
        await refusalCode(erin, 'notify:id:26:@alice:inv26.invitations.chat@erin'),
        'AT0034');
  });

  test(
      'Quarantined notifications accepted across the atSign up to its total'
      ' refuse the next one', () async {
    AtSecondaryServerImpl.getInstance().gatekeeper = await Gatekeeper.load(
        GateStore(keyValueStore, alice),
        limits: const GateLimits(maxQuarantinedBytesEverywhere: 1000));
    await countedAlready(dave, 1, bytes: 1000);
    await gate().setRule('photos', GateMode.open);
    await gate().count(erin, 'profile.photos');
    expect(await refusalCode(erin, 'notify:id:30:@alice:pic.photos@erin'),
        'AT0034');
  });

  test('A restart does not reset a count', () async {
    await countedAlready(chuck, 10);
    AtSecondaryServerImpl.getInstance().gatekeeper =
        await Gatekeeper.load(GateStore(keyValueStore, alice));
    expect(
        await refusalCode(
            chuck, 'notify:id:27:@alice:inv27.invitations.chat@chuck'),
        'AT0034');
  });

  /// The answers to each of [sent], sent at once, each on its own connection
  /// from its atSign's atServer.
  Future<List<Object?>> atOnce(List<(Atsign, String)> sent) => Future.wait([
        for (final (Atsign other, String command) in sent)
          (() async {
            final DummyInboundConnection connection = DummyInboundConnection();
            connection.metadata
              ..isPolAuthenticated = true
              ..fromAtSign = other;
            try {
              return (await notifyHandler.processInternal(command, connection))
                  .data;
            } on Exception catch (e) {
              return GlobalExceptionHandler.getInstance().getErrorCode(e);
            }
          })()
      ]);

  test('Two exchanges at the limit at once accept exactly one', () async {
    await countedAlready(chuck, 9);
    final List<Object?> answers = await atOnce([
      (chuck, 'notify:id:28:@alice:inv28.invitations.chat@chuck'),
      (chuck, 'notify:id:29:@alice:inv29.invitations.chat@chuck'),
    ]);
    expect(answers.toSet(), {'data:success', 'AT0034'});
  });

  test(
      'Two atSigns seen for the first time, competing for the last place,'
      ' admit exactly one to quarantine', () async {
    await gate().setRule(inv, GateMode.open,
        setting: GateSetting.maxQuarantined, value: 2);
    await countedAlready(chuck, 1);
    final List<Object?> answers = await atOnce([
      (erin, 'notify:id:32:@alice:inv32.invitations.chat@erin'),
      (frank, 'notify:id:33:@alice:inv33.invitations.chat@frank'),
    ]);
    expect(answers.toSet(), {'data:success', 'AT0034'});
  });
}
