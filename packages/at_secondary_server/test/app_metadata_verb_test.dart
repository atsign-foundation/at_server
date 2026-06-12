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
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
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
      updateHandler = UpdateVerbHandler(
          keyValueStore, statsNotificationService, notificationManager, alice);
      llookupHandler = LocalLookupVerbHandler(keyValueStore, enMgr);
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
          keyValueStore, statsNotificationService, notificationManager, alice);
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
      final notifyHandler =
          NotifyVerbHandler(keyValueStore, notificationManager);

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
  });
}
