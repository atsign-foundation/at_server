// Round-trip tests for Metadata.appMetadata through the update,
// update:meta and notify verb handlers:
//   wire fragment -> verb regex -> AtMetaData -> keystore -> llookup
// plus the server-to-server notify command body and the
// monitor-delivery map.
//
// Isolation: per-test, via verbTestsSetUp/verbTestsTearDown (same as
// update_verb_test.dart).

import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  AppMetadata sampleAppMetadata() => AppMetadata(
        providerId: 'acme_provider',
        additional: {'keyId': 'k-123', 'mode': 'hpke'},
      );

  String encoded() => Metadata.encodeAppMetadata(sampleAppMetadata());

  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group('appMetadata verb regex parsing', () {
    test('update command with appMetadata parses', () {
      final paramsMap = getVerbParam(Update().syntax(),
          'update:appMetadata:${encoded()}:@bob:phone.wavi$alice hello');
      expect(paramsMap[AtConstants.appMetadata], encoded());
    });

    test('update:meta command with appMetadata parses', () {
      final paramsMap = getVerbParam(UpdateMeta().syntax(),
          'update:meta:@bob:phone.wavi$alice:appMetadata:${encoded()}');
      expect(paramsMap[AtConstants.appMetadata], encoded());
    });

    test('notify command with appMetadata parses', () {
      final paramsMap = getVerbParam(Notify().syntax(),
          'notify:id:abc-123:appMetadata:${encoded()}:@bob:phone.wavi$alice');
      expect(paramsMap[AtConstants.appMetadata], encoded());
    });
  });

  group('update / update:meta round-trip through the keystore', () {
    late UpdateVerbHandler updateHandler;
    late LocalLookupVerbHandler llookupHandler;

    setUp(() {
      updateHandler = UpdateVerbHandler(keyValueStore, verbHandlerContext,
          statsNotificationService, notificationManager, alice);
      llookupHandler =
          LocalLookupVerbHandler(keyValueStore, verbHandlerContext, enMgr);
      inboundConnection.metadata.isAuthenticated = true;
    });

    Future<Metadata> llookupAllMetadata(String fullKeyName) async {
      await llookupHandler.process(
          'llookup:all:$fullKeyName', inboundConnection);
      final mapSentToClient =
          decodeResponse(inboundConnection.lastWrittenData!);
      return AtMetaData.fromJson(mapSentToClient['metaData'])
          .toCommonsMetadata();
    }

    test('update with appMetadata; llookup:all returns it', () async {
      await updateHandler.process(
          'update:appMetadata:${encoded()}:@bob:phone.wavi$alice hello',
          inboundConnection);

      final metadata = await llookupAllMetadata('@bob:phone.wavi$alice');
      expect(metadata.appMetadata, sampleAppMetadata());
    });

    test('a subsequent update without appMetadata retains it', () async {
      await updateHandler.process(
          'update:appMetadata:${encoded()}:@bob:phone.wavi$alice hello',
          inboundConnection);
      await updateHandler.process(
          'update:@bob:phone.wavi$alice goodbye', inboundConnection);

      final metadata = await llookupAllMetadata('@bob:phone.wavi$alice');
      expect(metadata.appMetadata, sampleAppMetadata());
    });

    test('update:meta sets appMetadata on an existing key', () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice hello', inboundConnection);

      final updateMetaHandler = UpdateMetaVerbHandler(
          keyValueStore,
          verbHandlerContext,
          statsNotificationService,
          notificationManager,
          alice);
      await updateMetaHandler.process(
          'update:meta:@bob:phone.wavi$alice:appMetadata:${encoded()}',
          inboundConnection);

      final metadata = await llookupAllMetadata('@bob:phone.wavi$alice');
      expect(metadata.appMetadata, sampleAppMetadata());

      // And the value was untouched.
      await llookupHandler.process(
          'llookup:@bob:phone.wavi$alice', inboundConnection);
      expect(inboundConnection.lastWrittenData, startsWith('data:hello'));
    });

    test('a subsequent update:meta changing other fields retains appMetadata',
        () async {
      // Establish appMetadata.
      await updateHandler.process(
          'update:appMetadata:${encoded()}:@bob:phone.wavi$alice hello',
          inboundConnection);

      // update:meta touching only OTHER metadata fields (ttl + encKeyName),
      // not appMetadata.
      final updateMetaHandler = UpdateMetaVerbHandler(
          keyValueStore,
          verbHandlerContext,
          statsNotificationService,
          notificationManager,
          alice);
      await updateMetaHandler.process(
          'update:meta:@bob:phone.wavi$alice:ttl:60000:encKeyName:some_key',
          inboundConnection);

      final metadata = await llookupAllMetadata('@bob:phone.wavi$alice');
      // The changed fields took effect...
      expect(metadata.ttl, 60000);
      expect(metadata.encKeyName, 'some_key');
      // ...and appMetadata, which the command didn't mention, was retained.
      expect(metadata.appMetadata, sampleAppMetadata());
    });

    test('malformed appMetadata is rejected as invalid syntax', () async {
      await expectLater(
          updateHandler.process(
              'update:appMetadata:not-valid-base64!:@bob:phone.wavi$alice hi',
              inboundConnection),
          throwsA(isA<InvalidSyntaxException>()));
    });
  });

  group('notify round-trip', () {
    test(
        'notify with appMetadata stores it on the notification, '
        'the monitor map carries it, and the outbound command '
        're-parses with it intact', () async {
      inboundConnection.metadata.isAuthenticated = true;
      final notifyHandler = NotifyVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);

      await notifyHandler.process(
          'notify:id:app-meta-notify-1:notifier:system'
          ':appMetadata:${encoded()}:@bob:phone.wavi$alice',
          inboundConnection);

      final stored = await notifStore.get('app-meta-notify-1');
      expect(stored, isNotNull);
      expect(stored!.atMetadata?.appMetadata, sampleAppMetadata());

      // Monitor delivery: the client parses metadata.appMetadata with
      // Metadata.decodeAppMetadata (Map or base64 string accepted).
      final mapForClient = stored.mapForClient;
      final delivered = Metadata.decodeAppMetadata(
          mapForClient['metadata'][AtConstants.appMetadata]);
      expect(delivered, sampleAppMetadata());
      // And the map survives jsonEncode (what monitor actually sends).
      expect(jsonDecode(jsonEncode(mapForClient)), isA<Map>());

      // Server-to-server: the outbound notify command body must carry
      // appMetadata in a form the receiving server's regex accepts.
      final commandBody = notificationManager.prepareNotifyCommandBody(stored);
      final HashMap<String, String?> reParsed =
          getVerbParam(Notify().syntax(), 'notify:$commandBody');
      expect(Metadata.decodeAppMetadata(reParsed[AtConstants.appMetadata]),
          sampleAppMetadata());
    });

    test('notify with malformed appMetadata is rejected as invalid syntax',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      final notifyHandler = NotifyVerbHandler(
          keyValueStore, verbHandlerContext, notificationManager);
      await expectLater(
          notifyHandler.process(
              'notify:id:bad-app-meta:notifier:system'
              ':appMetadata:not-valid-base64!:@bob:phone.wavi$alice',
              inboundConnection),
          throwsA(isA<InvalidSyntaxException>()));
    });
  });

  group('appMetadata on every read / delivery path', () {
    test('unauthenticated lookup:all of a public key returns appMetadata',
        () async {
      // Seed a public key carrying appMetadata, as the owner.
      inboundConnection.metadata.isAuthenticated = true;
      final updateHandler = UpdateVerbHandler(keyValueStore, verbHandlerContext,
          statsNotificationService, notificationManager, alice);
      await updateHandler.process(
          'update:appMetadata:${encoded()}:public:city.wavi$alice tokyo',
          inboundConnection);

      // Look it up over a fresh, unauthenticated connection.
      final unauthConnection = DummyInboundConnection();
      final lookupHandler = LookupVerbHandler(keyValueStore, verbHandlerContext,
          mockOutboundClientManager, cacheManager, enMgr,
          accessLog: atAccessLog);
      await lookupHandler.process(
          'lookup:all:city.wavi$alice', unauthConnection);

      final mapSentToClient = decodeResponse(unauthConnection.lastWrittenData!);
      final metadata =
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata();
      expect(metadata.appMetadata, sampleAppMetadata());
    });

    test(
        'lookup of another atSign\'s shared key preserves appMetadata in '
        'the response AND in the cached copy', () async {
      inboundConnection.metadata.isAuthenticated = true;
      const keyName = 'some_key.some_namespace@bob';

      final AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      bobData.metaData!.appMetadata = sampleAppMetadata();
      final String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      final lookupHandler = LookupVerbHandler(keyValueStore, verbHandlerContext,
          mockOutboundClientManager, cacheManager, enMgr,
          accessLog: atAccessLog);
      await lookupHandler.process('lookup:all:$keyName', inboundConnection);

      final mapSentToClient =
          decodeResponse(inboundConnection.lastWrittenData!);
      final metadata =
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata();
      expect(metadata.appMetadata, sampleAppMetadata());

      // The cached copy persisted appMetadata too.
      final cached = await keyValueStore.get('cached:$alice:$keyName');
      expect(cached!.metaData!.appMetadata, sampleAppMetadata());
    });

    test('plookup of a public key preserves appMetadata', () async {
      inboundConnection.metadata.isAuthenticated = true;
      const keyName = 'first_name.wavi@bob';

      final AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      bobData.metaData!.appMetadata = sampleAppMetadata();
      final String bobDataAsJson = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: 'public:$keyName')!;

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJson\n$alice@".codeUnits);
      });

      final plookupHandler = ProxyLookupVerbHandler(keyValueStore,
          verbHandlerContext, mockOutboundClientManager, cacheManager,
          accessLog: atAccessLog);
      await plookupHandler.process('plookup:all:$keyName', inboundConnection);

      final mapSentToClient =
          decodeResponse(inboundConnection.lastWrittenData!);
      final metadata =
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata();
      expect(metadata.appMetadata, sampleAppMetadata());
    });

    test(
        'autoNotify: an update of a key shared with another atSign creates '
        'a notification carrying appMetadata', () async {
      inboundConnection.metadata.isAuthenticated = true;
      AbstractUpdateVerbHandler.setAutoNotify(true);
      try {
        final updateHandler = UpdateVerbHandler(
            keyValueStore,
            verbHandlerContext,
            statsNotificationService,
            notificationManager,
            alice);
        await updateHandler.process(
            'update:appMetadata:${encoded()}:$bob:auto-notified.wavi$alice hi',
            inboundConnection);

        // Find the notification the update generated.
        AtNotification? generated;
        for (final id in await (await notifStore.getKeys()).toList()) {
          final n = await notifStore.get(id);
          if (n != null && n.notification!.contains('auto-notified.wavi')) {
            generated = n;
            break;
          }
        }
        expect(generated, isNotNull,
            reason: 'autoNotify should have stored a notification');
        expect(generated!.atMetadata?.appMetadata, sampleAppMetadata());
      } finally {
        AbstractUpdateVerbHandler.setAutoNotify(false);
      }
    });

    test(
        'sync response metadata carries appMetadata, base64-encoded as '
        'Metadata.decodeAppMetadata expects', () async {
      inboundConnection.metadata.isAuthenticated = true;
      await keyValueStore.put(
          'synced.wavi$alice',
          AtData()
            ..data = 'sync-me'
            ..metaData = (AtMetaData()..appMetadata = sampleAppMetadata()));

      final syncHandler = SyncProgressiveVerbHandler(
          keyValueStore, verbHandlerContext,
          commitLog: atCommitLog);
      final response = Response();
      final verbParams = HashMap<String, String?>();
      verbParams[AtConstants.fromCommitSequence] = '-1';
      await syncHandler.processVerb(response, verbParams, inboundConnection);

      final List syncResponse = jsonDecode(response.data!);
      final Map entry = syncResponse
          .firstWhere((e) => e['atKey'] == 'synced.wavi$alice') as Map;
      final encodedOnWire = entry['metadata'][AtConstants.appMetadata];
      expect(encodedOnWire, isA<String>());
      expect(Metadata.decodeAppMetadata(encodedOnWire), sampleAppMetadata());
    });
  });
}
