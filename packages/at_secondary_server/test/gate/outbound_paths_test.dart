import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_all_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:crypton/crypton.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The outbound paths with no scenario of their own: a delete's
/// notification, notify:all, and the cache manager's lookups for @alice.
void main() {
  final Atsign chuck = '@chuck'.toAtsign();

  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    await gate().setDefault(GateDefault.closed);
    await gate().setRule('chat', GateMode.closed, admit: bob);
    AtSecondaryServerImpl.getInstance().signingKey =
        RSAKeypair.fromRandom().privateKey.toString();
  });

  tearDown(() async => await verbTestsTearDown());

  DummyInboundConnection ownClient() => DummyInboundConnection()
    ..metadata.isAuthenticated = true
    ..metadata.authType = AuthType.cram;

  Future<List<AtNotification>> heldFor(String other) async =>
      [for (final n in await notifStore.iterate().toList()) if (n.toAtSign == other) n];

  group('Given namespace "chat" closed, admitting only @bob', () {
    test(
        'when keys shared with @bob and @chuck are deleted, then both go and'
        ' only @bob is notified', () async {
      for (final String other in [bob, '$chuck']) {
        await keyValueStore.put(
            '$other:status.chat$alice', AtData()..data = 'v');
        await DeleteVerbHandler(
                keyValueStore, statsNotificationService, notificationManager)
            .processInternal('delete:$other:status.chat$alice', ownClient());
        expect(await keyValueStore.exists('$other:status.chat$alice'), isFalse);
      }
      expect(await heldFor(bob), hasLength(1));
      expect(await heldFor('$chuck'), isEmpty);
    });

    test(
        'when notify:all names @bob and @chuck, then @bob is queued and'
        ' @chuck answers null with nothing queued', () async {
      final Response response = Response();
      await NotifyAllVerbHandler(keyValueStore, notificationManager)
          .processVerb(
              response,
              getVerbParam(VerbSyntax.notifyAll,
                  'notify:all:$bob,$chuck:msg.chat$alice'),
              ownClient());
      final Map<String, dynamic> reply = jsonDecode(response.data!);
      expect(reply[bob], (await heldFor(bob)).single.id);
      expect(reply.containsKey('$chuck'), isTrue);
      expect(reply['$chuck'], isNull);
      expect(await heldFor('$chuck'), isEmpty);
    });

    test(
        'when @alice looks up a key of @chuck in it that she holds a cached'
        ' copy of, then the lookup is refused and the copy is not served',
        () async {
      for (final (String other, String value) in [
        ('$chuck', 'stale'),
        (bob, 'current'),
      ]) {
        await keyValueStore.put(
            'cached:$alice:status.chat$other',
            AtData()
              ..data = value
              ..metaData = (AtMetaData()..ttr = -1));
      }
      final LookupVerbHandler lookup = LookupVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
          accessLog: atAccessLog);
      expect(
          (await lookup.processInternal('lookup:status.chat$bob', ownClient()))
              .data,
          'current');
      await expectLater(
          lookup.processInternal('lookup:status.chat$chuck', ownClient()),
          throwsA(isA<NotAcceptedException>()));
    });

    test(
        "when @bob's atServer refuses @alice's lookup of a key she holds a"
        ' copy of, then the copy goes', () async {
      await keyValueStore.put(
          'cached:$alice:status.chat$bob',
          AtData()
            ..data = 'old'
            ..metaData = (AtMetaData()..ttr = 1));
      await Future.delayed(const Duration(milliseconds: 1100));
      final MockOutboundClient client = MockOutboundClient();
      when(() => client.lookUp(any(), handshake: any(named: 'handshake')))
          .thenThrow(NotAcceptedException('not accepted'));
      when(() => mockOutboundClientManager.getClient(bob, any(),
              handshakeRequired: any(named: 'handshakeRequired')))
          .thenAnswer((_) async => client);
      await expectLater(
          LookupVerbHandler(keyValueStore, mockOutboundClientManager,
                  cacheManager, enMgr,
                  accessLog: atAccessLog)
              .processInternal('lookup:status.chat$bob', ownClient()),
          throwsA(isA<NotAcceptedException>()));
      expect(
          await keyValueStore.exists('cached:$alice:status.chat$bob'), isFalse);
    });

    test(
        'when the cache manager is asked for a key of @chuck in it, then it'
        ' refuses before connecting', () async {
      await expectLater(
          cacheManager.remoteLookUp('cached:$alice:status.chat$chuck'),
          throwsA(isA<NotAcceptedException>()));
      verifyNever(() => mockOutboundClientManager.getClient('$chuck', any(),
          handshakeRequired: any(named: 'handshakeRequired')));
    });
  });
}
