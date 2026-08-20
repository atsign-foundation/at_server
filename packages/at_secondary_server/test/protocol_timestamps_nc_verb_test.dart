// The update/update:meta/update:json/delete halves of the at_commons 5.10.0
// protocol enhancements, at the verb layer:
//
//   * :cAt/:uAt/:eAt/:aAt — caller-asserted timestamps stored faithfully
//     (wire fragment -> verb regex -> AtAssertedTimestamps -> keystore ->
//     llookup:all)
//   * :nc — perform the operation, write no commit entry, purge the key's
//     existing entry, respond data:-1; autoNotify unaffected
//   * delete:dAt — recorded as the DELETE commit entry's opTime
//   * the auto-notification carries the STORED metadata (queued after the
//     write)
//
// Isolation: per-test, via verbTestsSetUp/verbTestsTearDown (same as
// update_verb_test.dart).

import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  // Wire form carries microseconds; the store holds milliseconds.
  const cAtWire = '2020-01-02T03:04:05.678901Z';
  final cAtStored = DateTime.utc(2020, 1, 2, 3, 4, 5, 678);
  const uAtWire = '2021-02-03T04:05:06.789012Z';
  final uAtStored = DateTime.utc(2021, 2, 3, 4, 5, 6, 789);
  const eAtWire = '2030-01-01T00:00:00.000000Z';
  final eAtStored = DateTime.utc(2030, 1, 1);
  const aAtWire = '2022-03-04T05:06:07.890123Z';
  final aAtStored = DateTime.utc(2022, 3, 4, 5, 6, 7, 890);

  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  late UpdateVerbHandler updateHandler;
  late UpdateMetaVerbHandler updateMetaHandler;
  late DeleteVerbHandler deleteHandler;
  late LocalLookupVerbHandler llookupHandler;

  setUp(() async {
    await verbTestsSetUp();
    updateHandler = UpdateVerbHandler(
        keyValueStore, statsNotificationService, notificationManager, alice);
    updateMetaHandler = UpdateMetaVerbHandler(
        keyValueStore, statsNotificationService, notificationManager, alice);
    deleteHandler = DeleteVerbHandler(
        keyValueStore, statsNotificationService, notificationManager);
    llookupHandler = LocalLookupVerbHandler(keyValueStore, enMgr);
    inboundConnection.metadata.isAuthenticated = true;
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  Future<AtMetaData> llookupAllAtMetaData(String fullKeyName) async {
    await llookupHandler.process('llookup:all:$fullKeyName', inboundConnection);
    final mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
    return AtMetaData.fromJson(mapSentToClient['metaData']);
  }

  int lastResponseAsInt() => int.parse(
      inboundConnection.lastWrittenData!.split('\n')[0].replaceAll('data:', ''));

  Future<List<dynamic>> syncFromMinusOne() async {
    final syncHandler =
        SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
    final response = Response();
    final verbParams = HashMap<String, String?>();
    verbParams[AtConstants.fromCommitSequence] = '-1';
    await syncHandler.processVerb(response, verbParams, inboundConnection);
    return jsonDecode(response.data!);
  }

  group('asserted timestamps via update', () {
    test('update with cAt/uAt/eAt/aAt stores them faithfully (ms-truncated)',
        () async {
      await updateHandler.process(
          'update:cAt:$cAtWire:uAt:$uAtWire:eAt:$eAtWire:aAt:$aAtWire'
          ':@bob:phone.wavi$alice hello',
          inboundConnection);

      final meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.createdAt, cAtStored);
      expect(meta.updatedAt, uAtStored);
      expect(meta.expiresAt, eAtStored);
      expect(meta.availableAt, aAtStored);
    });

    test('asserted cAt on an EXISTING key overwrites stored createdAt',
        () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice hello', inboundConnection);
      final original = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(original.createdAt, isNot(cAtStored));

      await updateHandler.process(
          'update:cAt:$cAtWire:@bob:phone.wavi$alice hello2',
          inboundConnection);
      final meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.createdAt, cAtStored,
          reason: 'an explicit cAt assertion wins on update as on create');
    });

    test('without assertions, behaviour is unchanged: createdAt preserved, '
        'updatedAt re-stamped', () async {
      await updateHandler.process(
          'update:cAt:$cAtWire:uAt:$uAtWire:@bob:phone.wavi$alice v1',
          inboundConnection);
      final before = DateTime.now().toUtcMillisecondsPrecision();
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v2', inboundConnection);

      final meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.createdAt, cAtStored);
      expect(meta.updatedAt!.isBefore(before), isFalse,
          reason: 'updatedAt is server-stamped when no uAt is asserted');
    });

    test('asserted eAt wins over ttl derivation at that write; a later '
        'ttl-bearing write re-derives', () async {
      await updateHandler.process(
          'update:ttl:86400000:eAt:$eAtWire:@bob:phone.wavi$alice v1',
          inboundConnection);
      var meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.expiresAt, eAtStored,
          reason: 'the transmitted absolute expiry must not be re-derived '
              'from now+ttl on arrival');
      expect(meta.ttl, 86400000);

      final before = DateTime.now().toUtcMillisecondsPrecision();
      await updateHandler.process(
          'update:ttl:86400000:@bob:phone.wavi$alice v2', inboundConnection);
      meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.expiresAt, isNot(eAtStored));
      expect(meta.expiresAt!.isAfter(before), isTrue,
          reason: 'without an eAt assertion, ttl re-derives from now');
    });

    test('update:meta with uAt/eAt stores them faithfully', () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      await updateMetaHandler.process(
          'update:meta:@bob:phone.wavi$alice:uAt:$uAtWire:eAt:$eAtWire',
          inboundConnection);

      final meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.updatedAt, uAtStored);
      expect(meta.expiresAt, eAtStored);
    });

    test('update:json with eAt and NO ttl: the asserted expiry survives the '
        'json path\'s ttl-to-0 coercion', () async {
      // Metadata.fromJson coerces an absent ttl to 0, and ttl:0 normally
      // CLEARS expiresAt — the assertion must beat that derivation. The
      // metadata map is built through commons Metadata.toJson, the shape
      // every real client emits.
      final metadataJson = (Metadata()
            ..expiresAt = DateTime.parse(eAtWire)
            ..availableAt = DateTime.parse(aAtWire))
          .toJson();
      final json = jsonEncode({
        'atKey': 'phone.wavi',
        'value': 'json-value',
        'sharedBy': alice,
        'sharedWith': '@bob',
        'metadata': metadataJson,
      });
      await updateHandler.process('update:json:$json', inboundConnection);

      final meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.expiresAt, eAtStored);
      expect(meta.availableAt, aAtStored);
    });

    test('update:json with createdAt/updatedAt stores them faithfully',
        () async {
      final metadataJson = (Metadata()
            ..createdAt = DateTime.parse(cAtWire)
            ..updatedAt = DateTime.parse(uAtWire))
          .toJson();
      final json = jsonEncode({
        'atKey': 'phone.wavi',
        'value': 'json-value',
        'sharedBy': alice,
        'sharedWith': '@bob',
        'metadata': metadataJson,
      });
      await updateHandler.process('update:json:$json', inboundConnection);

      final meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.createdAt, cAtStored);
      expect(meta.updatedAt, uAtStored);
    });

    test('update with uAt records it as the commit entry\'s opTime', () async {
      await updateHandler.process(
          'update:uAt:$uAtWire:@bob:phone.wavi$alice v1', inboundConnection);
      final entry = atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice')!;
      expect(entry.opTime, uAtStored);
    });

    test('a non-UTC timestamp does not match the grammar', () async {
      await expectLater(
          updateHandler.process(
              'update:cAt:2020-01-02T03:04:05.678901:@bob:phone.wavi$alice v',
              inboundConnection),
          throwsA(isA<InvalidSyntaxException>()));
    });
  });

  group(':nc on update / update:meta / update:json', () {
    test('update:nc responds data:-1, stores the value, purges the commit '
        'entry', () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      expect(
          atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice'), isNotNull);

      await updateHandler.process(
          'update:nc:@bob:phone.wavi$alice v2', inboundConnection);
      expect(lastResponseAsInt(), -1);
      expect(atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice'), isNull,
          reason: 'a no-commit update scrubs the key\'s previous entry');

      await llookupHandler.process(
          'llookup:@bob:phone.wavi$alice', inboundConnection);
      expect(inboundConnection.lastWrittenData, startsWith('data:v2'),
          reason: 'the write itself still happens');
    });

    test('after update:nc, sync no longer returns an entry for the key',
        () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      var syncEntries = await syncFromMinusOne();
      expect(syncEntries.where((e) => e['atKey'] == '@bob:phone.wavi$alice'),
          isNotEmpty);

      await updateHandler.process(
          'update:nc:@bob:phone.wavi$alice v2', inboundConnection);
      syncEntries = await syncFromMinusOne();
      expect(syncEntries.where((e) => e['atKey'] == '@bob:phone.wavi$alice'),
          isEmpty);
    });

    test('update:meta:nc responds data:-1 and purges', () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      await updateMetaHandler.process(
          'update:meta:nc:@bob:phone.wavi$alice:ttl:60000', inboundConnection);
      expect(lastResponseAsInt(), -1);
      expect(atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice'), isNull);

      final meta = await llookupAllAtMetaData('@bob:phone.wavi$alice');
      expect(meta.ttl, 60000, reason: 'the metadata write itself happened');
    });

    test('update:nc:json responds data:-1 and purges', () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      final json = jsonEncode({
        'atKey': 'phone.wavi',
        'value': 'v2',
        'sharedBy': alice,
        'sharedWith': '@bob',
        'metadata': Metadata().toJson(),
      });
      await updateHandler.process('update:nc:json:$json', inboundConnection);
      expect(lastResponseAsInt(), -1);
      expect(atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice'), isNull);
    });

    test('update:nc still autoNotifies the sharedWith atSign', () async {
      AbstractUpdateVerbHandler.setAutoNotify(true);
      try {
        await updateHandler.process(
            'update:nc:$bob:nc-notified.wavi$alice hi', inboundConnection);

        AtNotification? generated;
        for (final id in await (await notifStore.getKeys()).toList()) {
          final n = await notifStore.get(id);
          if (n != null && n.notification!.contains('nc-notified.wavi')) {
            generated = n;
            break;
          }
        }
        expect(generated, isNotNull,
            reason: ':nc changes commit-log behaviour ONLY — the operation, '
                'including its auto-notification, runs as usual');
      } finally {
        AbstractUpdateVerbHandler.setAutoNotify(false);
      }
    });
  });

  group('delete:dAt and delete:nc', () {
    test('delete:dAt records the asserted time as the DELETE entry\'s opTime',
        () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      await deleteHandler.process(
          'delete:dAt:$uAtWire:@bob:phone.wavi$alice', inboundConnection);

      final entry = atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice')!;
      expect(entry.operation, CommitOp.DELETE);
      expect(entry.opTime, uAtStored);
    });

    test('delete:nc responds data:-1 and purges; the cruft case (key already '
        'gone) purges too', () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      await deleteHandler.process(
          'delete:@bob:phone.wavi$alice', inboundConnection);
      expect(atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice')!
          .operation, CommitOp.DELETE,
          reason: 'a normal delete leaves the DELETE entry — the cruft');

      // The key no longer exists; delete:nc must still purge its entry.
      await deleteHandler.process(
          'delete:nc:@bob:phone.wavi$alice', inboundConnection);
      expect(lastResponseAsInt(), -1);
      expect(atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice'), isNull);
    });

    test('delete:dAt:nc parses; dAt is moot (no entry to stamp)', () async {
      await updateHandler.process(
          'update:@bob:phone.wavi$alice v1', inboundConnection);
      await deleteHandler.process(
          'delete:dAt:$uAtWire:nc:@bob:phone.wavi$alice', inboundConnection);
      expect(lastResponseAsInt(), -1);
      expect(atCommitLog.getLatestCommitEntry('@bob:phone.wavi$alice'), isNull);
    });

    test('delete:nc still autoNotifies the sharedWith atSign', () async {
      AbstractUpdateVerbHandler.setAutoNotify(true);
      try {
        await updateHandler.process(
            'update:$bob:nc-deleted.wavi$alice hi', inboundConnection);
        await deleteHandler.process(
            'delete:nc:$bob:nc-deleted.wavi$alice', inboundConnection);

        AtNotification? deleteNotification;
        for (final id in await (await notifStore.getKeys()).toList()) {
          final n = await notifStore.get(id);
          if (n != null &&
              n.notification!.contains('nc-deleted.wavi') &&
              n.opType == OperationType.delete) {
            deleteNotification = n;
            break;
          }
        }
        expect(deleteNotification, isNotNull,
            reason: ':nc changes commit-log behaviour ONLY');
      } finally {
        AbstractUpdateVerbHandler.setAutoNotify(false);
      }
    });
  });

  group('the auto-notification carries the STORED metadata', () {
    test('updating an existing key notifies with the stored (old) createdAt, '
        'not a freshly-fabricated one', () async {
      AbstractUpdateVerbHandler.setAutoNotify(true);
      try {
        await updateHandler.process(
            'update:cAt:$cAtWire:$bob:stored-meta.wavi$alice v1',
            inboundConnection);
        await updateHandler.process(
            'update:$bob:stored-meta.wavi$alice v2', inboundConnection);

        final notifications = <AtNotification>[];
        for (final id in await (await notifStore.getKeys()).toList()) {
          final n = await notifStore.get(id);
          if (n != null && n.notification!.contains('stored-meta.wavi')) {
            notifications.add(n);
          }
        }
        expect(notifications, isNotEmpty);
        for (final n in notifications) {
          expect(n.atMetadata?.createdAt, cAtStored,
              reason: 'the notification must carry what the store holds — '
                  'a pre-store fabricated createdAt would transmit a wrong '
                  'value to the other atServer');
        }
      } finally {
        AbstractUpdateVerbHandler.setAutoNotify(false);
      }
    });
  });
}
