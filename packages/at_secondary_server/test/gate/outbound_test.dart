import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// Catalogue: docs/projects/gatekeeper/features/outbound.feature
///
/// The scenarios whose observable is what @alice's atServer does with her
/// own exchanges, each under its title.
void main() {
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();
  const String inv = 'invitations.chat';

  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    await gate().setDefault(GateDefault.closed);
  });

  tearDown(() async => await verbTestsTearDown());

  DummyInboundConnection ownClient() => DummyInboundConnection()
    ..metadata.isAuthenticated = true
    ..metadata.authType = AuthType.cram;

  NotifyVerbHandler notifyHandler() =>
      NotifyVerbHandler(keyValueStore, notificationManager);

  LookupVerbHandler lookupHandler() => LookupVerbHandler(
      keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
      accessLog: atAccessLog);

  Future<String?> clientSends(
          AbstractVerbHandler handler, String command) async =>
      (await handler.processInternal(command, ownClient())).data;

  Future<String?> refusalCode(AbstractVerbHandler handler, String command) async {
    Exception? refused;
    try {
      await handler.processInternal(command, ownClient());
    } on Exception catch (e) {
      refused = e;
    }
    expect(refused, isNotNull, reason: '"$command" was not refused');
    return GlobalExceptionHandler.getInstance().getErrorCode(refused!);
  }

  Future<List<AtNotification>> heldFor(Atsign other) async => [
        for (final String id in await notificationManager.getKeys())
          if ((await notificationManager.get(id))!.toAtSign == '$other')
            (await notificationManager.get(id))!
      ];

  void noConnectionTo(Atsign other) => verifyNever(() =>
      mockOutboundClientManager.getClient('$other', any(),
          handshakeRequired: any(named: 'handshakeRequired')));

  /// An outbound client for [other] that answers a scan with [keys].
  void scanAnswers(Atsign other, String keys) {
    final MockOutboundClient client = MockOutboundClient();
    when(() => client.isHandShakeDone).thenReturn(true);
    when(() => client.scan(
            handshake: any(named: 'handshake'), regex: any(named: 'regex')))
        .thenAnswer((_) async => 'data:$keys');
    when(() => mockOutboundClientManager.getClient('$other', any(),
            handshakeRequired: any(named: 'handshakeRequired')))
        .thenAnswer((_) async => client);
  }

  bool inNoneOfTheSets(Atsign other, String namespace) =>
      !gate().quarantinedIn(namespace).containsKey(other) &&
      !gate().ruleFor(namespace)!.admitted.contains(other) &&
      !gate().ruleFor(namespace)!.denied.contains(other);

  test(
      'A notification to an atSign a closed namespace has not admitted is'
      ' never sent', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(await refusalCode(notifyHandler(), 'notify:@chuck:msg.chat@alice'),
        'AT0033');
    expect(await heldFor(chuck), isEmpty);
    noConnectionTo(chuck);
  });

  test('A notification to an atSign a closed namespace has admitted is'
      ' delivered', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    final String? id =
        await clientSends(notifyHandler(), 'notify:@bob:msg.chat@alice');
    expect(id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect((await heldFor(bob)).map((n) => n.id), [id]);
  });

  test(
      'A lookup in a closed namespace of an atSign it has not admitted is'
      ' never sent', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(await refusalCode(lookupHandler(), 'lookup:status.chat@chuck'),
        'AT0033');
    noConnectionTo(chuck);
  });

  test('In an open namespace, @alice may notify an atSign seen for the first'
      ' time', () async {
    await gate().setRule(inv, GateMode.open);
    await clientSends(notifyHandler(), 'notify:@dave:inv1.invitations.chat@alice');
    expect(await heldFor(dave), hasLength(1));
    expect(inNoneOfTheSets(dave, inv), isTrue);
  });

  test('In an open namespace, @alice may notify a quarantined atSign',
      () async {
    await gate().setRule(inv, GateMode.open);
    await gate().count(chuck, 'x.$inv');
    await clientSends(
        notifyHandler(), 'notify:@chuck:no-thanks.invitations.chat@alice');
    expect(await heldFor(chuck), hasLength(1));
    expect(gate().quarantinedIn(inv)[chuck]!.counted.length, 1);
  });

  test('In an open namespace, @alice may not notify a denied atSign',
      () async {
    await gate().setRule(inv, GateMode.open);
    await gate().deny(inv, chuck);
    expect(
        await refusalCode(
            notifyHandler(), 'notify:@chuck:inv2.invitations.chat@alice'),
        'AT0033');
    noConnectionTo(chuck);
  });

  test("A lookup changes nobody's standing", () async {
    await gate().setRule(inv, GateMode.open);
    final MockOutboundClient client = MockOutboundClient();
    when(() => client.lookUp(any(), handshake: any(named: 'handshake')))
        .thenThrow(KeyNotFoundException('not there'));
    when(() => mockOutboundClientManager.getClient('$dave', any(),
            handshakeRequired: any(named: 'handshakeRequired')))
        .thenAnswer((_) async => client);
    try {
      await clientSends(lookupHandler(), 'lookup:profile.invitations.chat@dave');
    } on Exception {
      // The lookup reaching @dave's atServer is what this scenario observes.
    }
    verify(() => client.lookUp('all:profile.invitations.chat@dave',
        handshake: any(named: 'handshake'))).called(1);
    expect(inNoneOfTheSets(dave, inv), isTrue);
  });

  test(
      'A remote scan answers only keys in namespaces where @alice may reach'
      ' the other atSign', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await gate().setRule('photos', GateMode.open);
    scanAnswers(chuck, '["status.chat@chuck","pic.photos@chuck"]');
    expect(
        await clientSends(
            ScanVerbHandler(keyValueStore, mockOutboundClientManager, cacheManager),
            'scan:@chuck'),
        'data:["pic.photos@chuck"]');
  });

  test(
      "A remote scan's answer is judged on the atSign scanned, not on the"
      ' owner a key names', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await gate().setRule('photos', GateMode.open);
    scanAnswers(chuck, '["msg.chat@bob","pic.photos@chuck"]');
    expect(
        await clientSends(
            ScanVerbHandler(keyValueStore, mockOutboundClientManager, cacheManager),
            'scan:@chuck'),
        'data:["pic.photos@chuck"]');
  });

  test('The reply to an invitation arrives in quarantine', () async {
    await gate().setRule('chat', GateMode.closed);
    await gate().setRule(inv, GateMode.open);
    await clientSends(notifyHandler(), 'notify:@dave:inv1.invitations.chat@alice');
    final DummyInboundConnection fromDave = DummyInboundConnection()
      ..metadata.isPolAuthenticated = true
      ..metadata.fromAtSign = dave;
    expect(
        (await notifyHandler().processInternal(
                'notify:id:7:@alice:inv1.invitations.chat@dave', fromDave))
            .data,
        'data:success');
    expect(gate().quarantinedIn(inv), contains(dave));
  });

  test('Accepting an invitation is the application admitting the atSign',
      () async {
    await gate().setRule('chat', GateMode.closed);
    await gate().setRule(inv, GateMode.open);
    await gate().count(dave, 'x.$inv');
    await gate().admit('chat', dave);
    await clientSends(notifyHandler(), 'notify:@dave:msg.chat@alice');
    expect(await heldFor(dave), hasLength(1));
  });

  UpdateVerbHandler updateHandler() => UpdateVerbHandler(
      keyValueStore, statsNotificationService, notificationManager, alice);

  test('An update of a key shared with an admitted atSign is notified as today',
      () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(
        int.tryParse(
            (await clientSends(updateHandler(), 'update:@bob:status.chat@alice v'))!),
        isNotNull);
    expect((await heldFor(bob)).single.notification, '@bob:status.chat@alice');
  });

  test(
      'A key shared with an atSign the namespace refuses is stored, and not'
      ' notified', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(
        int.tryParse((await clientSends(
            updateHandler(), 'update:@chuck:status.chat@alice v'))!),
        isNotNull);
    expect(await keyValueStore.exists('@chuck:status.chat$alice'), isTrue);
    expect(await heldFor(chuck), isEmpty);
  });

  test('A stored key becomes reachable when its atSign is admitted', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await keyValueStore.put('@chuck:status.chat$alice', AtData()..data = 'v');
    await gate().admit('chat', chuck);
    final DummyInboundConnection fromChuck = DummyInboundConnection()
      ..metadata.isPolAuthenticated = true
      ..metadata.fromAtSign = chuck;
    expect((await lookupHandler().processInternal('lookup:status.chat@alice',
                fromChuck))
            .data,
        'v');
  });

  test(
      'Under the ungated default, @alice reaches anyone in a namespace without'
      ' a rule', () async {
    await gate().setDefault(GateDefault.ungated);
    await clientSends(notifyHandler(), 'notify:@chuck:pic.photos@alice');
    expect(await heldFor(chuck), hasLength(1));
  });

  group(
      'Under the closed default, @alice reaches only the atSigns the default'
      ' lets in', () {
    test('@bob', () async {
      await gate().admit(Gatekeeper.everyNamespace, bob);
      await clientSends(notifyHandler(), 'notify:@bob:pic.photos@alice');
      expect(await heldFor(bob), hasLength(1));
    });

    test('@chuck', () async {
      await gate().admit(Gatekeeper.everyNamespace, bob);
      expect(
          await refusalCode(notifyHandler(), 'notify:@chuck:pic.photos@alice'),
          'AT0033');
    });
  });

  /// Sends "config:block:[operation]:[other]" from @alice's root client.
  Future<void> blocklist(String operation, Atsign other) async =>
      await ConfigVerbHandler(keyValueStore, commitLog: atCommitLog)
          .processInternal('config:block:$operation:$other', ownClient());

  /// Namespace "chat" closed, admitting @bob and @chuck.
  Future<void> chatAdmittingBobAndChuck() async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await gate().admit('chat', chuck);
  }

  test(
      'A notification to a blocklisted atSign is never sent, whatever its'
      ' namespace admits', () async {
    await chatAdmittingBobAndChuck();
    await blocklist('add', chuck);
    expect(await refusalCode(notifyHandler(), 'notify:@chuck:msg.chat@alice'),
        'AT0033');
    expect(await heldFor(chuck), isEmpty);
    noConnectionTo(chuck);
  });

  test("A lookup of a blocklisted atSign's key is never sent", () async {
    await chatAdmittingBobAndChuck();
    await blocklist('add', chuck);
    expect(await refusalCode(lookupHandler(), 'lookup:status.chat@chuck'),
        'AT0033');
    noConnectionTo(chuck);
  });

  test('A key shared with a blocklisted atSign is stored, and not notified',
      () async {
    await chatAdmittingBobAndChuck();
    await blocklist('add', chuck);
    expect(
        int.tryParse((await clientSends(
            updateHandler(), 'update:@chuck:status.chat@alice v'))!),
        isNotNull);
    expect(await keyValueStore.exists('@chuck:status.chat$alice'), isTrue);
    expect(await heldFor(chuck), isEmpty);
  });

  test("A public lookup of a blocklisted atSign's record is answered as before",
      () async {
    await blocklist('add', chuck);
    final DateTime now = DateTime.now().toUtc();
    final MockOutboundClient client = MockOutboundClient();
    when(() => client.lookUp(any(), handshake: any(named: 'handshake')))
        .thenAnswer((_) async =>
            'data:${SecondaryUtil.prepareResponseData('all', AtData()
              ..data = 'chucks public key'
              ..metaData = (AtMetaData()
                ..createdAt = now
                ..updatedAt = now), key: 'public:publickey$chuck')}');
    when(() => mockOutboundClientManager.getClient('$chuck', any(),
            handshakeRequired: any(named: 'handshakeRequired')))
        .thenAnswer((_) async => client);
    expect(
        await clientSends(
            ProxyLookupVerbHandler(
                keyValueStore, mockOutboundClientManager, cacheManager,
                accessLog: atAccessLog),
            'plookup:publickey@chuck'),
        'chucks public key');
  });

  test('An atSign taken off the blocklist is reached again', () async {
    await chatAdmittingBobAndChuck();
    await blocklist('add', chuck);
    await blocklist('remove', chuck);
    final String? id =
        await clientSends(notifyHandler(), 'notify:@chuck:msg.chat@alice');
    expect((await heldFor(chuck)).map((n) => n.id), [id]);
  });
}
