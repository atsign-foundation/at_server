// End-to-end coverage (live atServer over the wire) for the at_commons
// 5.10.0 protocol enhancements (#2678):
//
//   * :cAt/:uAt/:eAt/:aAt — caller-asserted timestamps stored faithfully
//   * :nc — no commit entry, existing entry purged, response data:-1
//   * delete:dAt — recorded as the DELETE commit entry's opTime
//   * scan:cl — list commit-log entries
//
// Every key is uniqueId-scoped: the virtualenv atSign persists across the
// whole pack.

import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late String uniqueId;
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();

  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];
  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  // Wire timestamps and the exact spellings llookup:all's metaData JSON
  // uses for them (AtMetaData.toJson emits DateTime.toString()).
  const cAtWire = '2020-01-02T03:04:05.678000Z';
  const cAtJson = '2020-01-02 03:04:05.678Z';
  const uAtWire = '2021-02-03T04:05:06.789000Z';
  const uAtJson = '2021-02-03 04:05:06.789Z';
  const eAtWire = '2030-01-01T00:00:00.000000Z';
  const eAtJson = '2030-01-01 00:00:00.000Z';
  const dAtWire = '2023-05-05T11:59:44.123000Z';

  Map metaDataOfLlookupAll(String response) =>
      jsonDecode(response.replaceAll('data:', ''))['metaData'];

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success',
        reason: 'Authentication failed when executing test');
  });

  setUp(() {
    uniqueId = Uuid().v4();
  });

  tearDownAll(() async {
    await firstAtSignConnection.close();
  });

  group('asserted timestamps', () {
    test('update with cAt/uAt stores them faithfully', () async {
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:cAt:$cAtWire:uAt:$uAtWire'
          ':ts1-$uniqueId.wavi$firstAtSign hello');
      expect(response, matches(RegExp(r'^data:\d+$')),
          reason: 'an asserted-timestamp write is an ordinary COMMITTED '
              'write — a -1 here would mean it silently skipped its '
              'commit entry');

      response = await firstAtSignConnection
          .sendRequestToServer('llookup:all:ts1-$uniqueId.wavi$firstAtSign');
      final metaData = metaDataOfLlookupAll(response);
      expect(metaData['createdAt'], cAtJson);
      expect(metaData['updatedAt'], uAtJson);
    });

    test('asserted eAt wins over ttl derivation at that write', () async {
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:ttl:86400000:eAt:$eAtWire'
          ':ts2-$uniqueId.wavi$firstAtSign hello');
      expect(response, matches(RegExp(r'^data:\d+$')),
          reason: 'an asserted-timestamp write is an ordinary COMMITTED '
              'write — a -1 here would mean it silently skipped its '
              'commit entry');

      response = await firstAtSignConnection
          .sendRequestToServer('llookup:all:ts2-$uniqueId.wavi$firstAtSign');
      final metaData = metaDataOfLlookupAll(response);
      expect(metaData['expiresAt'], eAtJson,
          reason: 'the transmitted absolute expiry must not be rederived '
              'from now+ttl on arrival');
      expect(metaData['ttl'], 86400000);
    });

    test('update:json with eAt and no ttl keeps the asserted expiry',
        () async {
      final metadataJson =
          (Metadata()..expiresAt = DateTime.parse(eAtWire)).toJson();
      final json = jsonEncode({
        'atKey': 'ts3-$uniqueId.wavi',
        'value': 'json-value',
        'sharedBy': firstAtSign,
        'metadata': metadataJson,
      });
      String response =
          await firstAtSignConnection.sendRequestToServer('update:json:$json');
      expect(response, matches(RegExp(r'^data:\d+$')),
          reason: 'an asserted-timestamp write is an ordinary COMMITTED '
              'write — a -1 here would mean it silently skipped its '
              'commit entry');

      response = await firstAtSignConnection
          .sendRequestToServer('llookup:all:ts3-$uniqueId.wavi$firstAtSign');
      final metaData = metaDataOfLlookupAll(response);
      expect(metaData['expiresAt'], eAtJson);
    });

    test('a key with asserted eAt and no ttl actually expires', () async {
      // uAt is asserted BEYOND the eAt so the implied ttl is non-positive
      // and none is stored (a clock-skewed transfer) — this is the only
      // reachable expiresAt-without-ttl state now that an eAt-only write
      // derives and stores the ttl it implies, and it is the state that
      // proves the expiry machinery sees the asserted eAt itself.
      final soon = VerbUtil.formatIso8601Micros(
          DateTime.now().toUtc().add(Duration(seconds: 3)));
      final beyond = VerbUtil.formatIso8601Micros(
          DateTime.now().toUtc().add(Duration(seconds: 30)));
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:uAt:$beyond:eAt:$soon:ts4-$uniqueId.wavi$firstAtSign '
          'fleeting');
      expect(response, matches(RegExp(r'^data:\d+$')),
          reason: 'an asserted-timestamp write is an ordinary COMMITTED '
              'write — a -1 here would mean it silently skipped its '
              'commit entry');

      response =
          await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
      expect(response, contains('"ts4-$uniqueId.wavi$firstAtSign"'));

      await Future.delayed(Duration(seconds: 5));
      response =
          await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
      expect(response, isNot(contains('"ts4-$uniqueId.wavi$firstAtSign"')),
          reason: 'a key whose only expiry signal is an asserted eAt must '
              'stop being served at that instant');
    });

    test('update with eAt and no ttl derives and stores the implied ttl',
        () async {
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:uAt:$uAtWire:eAt:$eAtWire'
          ':ts5-$uniqueId.wavi$firstAtSign hello');
      expect(response, matches(RegExp(r'^data:\d+$')));

      response = await firstAtSignConnection
          .sendRequestToServer('llookup:all:ts5-$uniqueId.wavi$firstAtSign');
      final metaData = metaDataOfLlookupAll(response);
      expect(metaData['expiresAt'], eAtJson);
      expect(
          metaData['ttl'],
          DateTime.parse(eAtWire)
              .difference(DateTime.parse(uAtWire))
              .inMilliseconds,
          reason: 'a record with an absolute expiry also carries the ttl '
              'it implies, measured from the stored updatedAt');
    });

    test('a write that says nothing about expiry does not move expiresAt',
        () async {
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:ttl:86400000:ts6-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      response = await firstAtSignConnection
          .sendRequestToServer('llookup:all:ts6-$uniqueId.wavi$firstAtSign');
      final before = metaDataOfLlookupAll(response);
      expect(before['expiresAt'], isNotNull,
          reason: 'guards the comparison below — null == null would pass '
              'without the axis ever having been populated');

      // Far enough apart that a re-derivation from now would visibly move
      // the millisecond-precision expiresAt.
      await Future.delayed(Duration(milliseconds: 50));
      response = await firstAtSignConnection
          .sendRequestToServer('update:ts6-$uniqueId.wavi$firstAtSign v2');
      expect(response, matches(RegExp(r'^data:\d+$')));
      response = await firstAtSignConnection
          .sendRequestToServer('llookup:all:ts6-$uniqueId.wavi$firstAtSign');
      final after = metaDataOfLlookupAll(response);

      expect(after['expiresAt'], before['expiresAt'],
          reason: 'once set, expiresAt moves only when a request speaks '
              'about expiry: an eAt assertion, a fresh ttl, or ttl:0 — '
              'a value update must not restart the expiry clock');
      expect(after['ttl'], 86400000);
      expect(
          DateTime.parse(after['updatedAt'])
              .isAfter(DateTime.parse(before['updatedAt'])),
          isTrue,
          reason: 'proves the second write actually happened — the '
              'unchanged expiresAt must not be because the write was lost');
    });
  });

  group(':nc (no-commit)', () {
    test('update:nc responds data:-1 and removes the entry from sync',
        () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:nc1-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final commitId = int.parse(response.replaceAll('data:', ''));

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${commitId - 1}:limit:50:$uniqueId');
      expect(response, contains('"nc1-$uniqueId.wavi$firstAtSign"'));

      response = await firstAtSignConnection
          .sendRequestToServer('update:nc:nc1-$uniqueId.wavi$firstAtSign v2');
      expect(response, 'data:-1');

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${commitId - 1}:limit:50:$uniqueId');
      expect(response, isNot(contains('"nc1-$uniqueId.wavi$firstAtSign"')),
          reason: 'the no-commit write purges the key\'s commit entry, so '
              'sync must no longer serve one');

      response = await firstAtSignConnection
          .sendRequestToServer('llookup:nc1-$uniqueId.wavi$firstAtSign');
      expect(response, 'data:v2', reason: 'the write itself still happens');
    });

    test('a key created with update:nc never appears in sync', () async {
      // A committed sibling provides the sync watermark.
      String response = await firstAtSignConnection
          .sendRequestToServer('update:sibling-$uniqueId.wavi$firstAtSign s');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final watermark = int.parse(response.replaceAll('data:', ''));

      response = await firstAtSignConnection
          .sendRequestToServer('update:nc:born-$uniqueId.wavi$firstAtSign v1');
      expect(response, 'data:-1');

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${watermark - 1}:limit:50:$uniqueId');
      expect(response, contains('"sibling-$uniqueId.wavi$firstAtSign"'),
          reason: 'the committed sibling proves the sync request itself '
              'sees this test\'s keys');
      expect(response, isNot(contains('"born-$uniqueId.wavi$firstAtSign"')),
          reason: 'a key born with :nc has no commit entry to sync');

      response = await firstAtSignConnection
          .sendRequestToServer('llookup:born-$uniqueId.wavi$firstAtSign');
      expect(response, 'data:v1');
    });

    test('update:meta:nc removes the entry from sync', () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:ncm-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final commitId = int.parse(response.replaceAll('data:', ''));

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${commitId - 1}:limit:50:$uniqueId');
      expect(response, contains('"ncm-$uniqueId.wavi$firstAtSign"'));

      response = await firstAtSignConnection.sendRequestToServer(
          'update:meta:nc:ncm-$uniqueId.wavi$firstAtSign:ttl:60000');
      expect(response, 'data:-1');

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${commitId - 1}:limit:50:$uniqueId');
      expect(response, isNot(contains('"ncm-$uniqueId.wavi$firstAtSign"')),
          reason: 'the no-commit metadata write purges the key\'s entry');
    });

    test('a normal update after :nc re-enters sync with a fresh, higher '
        'commitId', () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:again-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final firstId = int.parse(response.replaceAll('data:', ''));

      response = await firstAtSignConnection
          .sendRequestToServer('update:nc:again-$uniqueId.wavi$firstAtSign v2');
      expect(response, 'data:-1');

      response = await firstAtSignConnection
          .sendRequestToServer('update:again-$uniqueId.wavi$firstAtSign v3');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final secondId = int.parse(response.replaceAll('data:', ''));
      expect(secondId > firstId, isTrue,
          reason: ':nc is not permanent — a later normal write re-commits '
              'under a fresh id');

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${firstId - 1}:limit:50:again-$uniqueId');
      final List entries = jsonDecode(response.replaceAll('data:', ''));
      expect(entries.length, 1,
          reason: 'sync serves exactly the one re-committed entry — the '
              'purged first entry must not reappear');
      expect(entries[0]['commitId'], secondId);
      expect(entries[0]['value'], 'v3');
    });

    test('delete:nc removes the DELETE tombstone from sync', () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:tomb-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final commitId = int.parse(response.replaceAll('data:', ''));

      response = await firstAtSignConnection
          .sendRequestToServer('delete:tomb-$uniqueId.wavi$firstAtSign');
      expect(response, matches(RegExp(r'^data:\d+$')));

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${commitId - 1}:limit:50:tomb-$uniqueId');
      List entries = jsonDecode(response.replaceAll('data:', ''));
      expect(entries.length, 1);
      expect(entries[0]['operation'], '-',
          reason: 'a normal delete leaves a tombstone that sync serves');

      response = await firstAtSignConnection
          .sendRequestToServer('delete:nc:tomb-$uniqueId.wavi$firstAtSign');
      expect(response, 'data:-1');

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${commitId - 1}:limit:50:tomb-$uniqueId');
      entries = jsonDecode(response.replaceAll('data:', ''));
      expect(entries, isEmpty,
          reason: 'delete:nc of the already-deleted key purges the '
              'tombstone; sync serves nothing for the key');
    });

    test('update:nc:json is absent from sync', () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:sib2-$uniqueId.wavi$firstAtSign s');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final watermark = int.parse(response.replaceAll('data:', ''));

      final json = jsonEncode({
        'atKey': 'jnc-$uniqueId.wavi',
        'value': 'jv',
        'sharedBy': firstAtSign,
        'metadata': Metadata().toJson(),
      });
      response = await firstAtSignConnection
          .sendRequestToServer('update:nc:json:$json');
      expect(response, 'data:-1');

      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${watermark - 1}:limit:50:$uniqueId');
      expect(response, contains('"sib2-$uniqueId.wavi$firstAtSign"'));
      expect(response, isNot(contains('"jnc-$uniqueId.wavi$firstAtSign"')));
    });

    test('update:meta:nc responds data:-1', () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:nc2-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));

      response = await firstAtSignConnection.sendRequestToServer(
          'update:meta:nc:nc2-$uniqueId.wavi$firstAtSign:ttl:60000');
      expect(response, 'data:-1');
    });

    test('delete:nc purges the leftover DELETE entry (the cruft case)',
        () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:nc3-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      response = await firstAtSignConnection
          .sendRequestToServer('delete:nc3-$uniqueId.wavi$firstAtSign');
      expect(response, matches(RegExp(r'^data:\d+$')));

      // The DELETE entry (the cruft) is visible in scan:cl...
      response =
          await firstAtSignConnection.sendRequestToServer('scan:cl $uniqueId');
      List entries = jsonDecode(response.replaceAll('data:', ''));
      expect(
          entries.cast<Map>().where((e) =>
              e['atKey'] == 'nc3-$uniqueId.wavi$firstAtSign' &&
              e['operation'] == '-'),
          isNotEmpty);

      // ...delete:nc of the already-gone key purges it.
      response = await firstAtSignConnection
          .sendRequestToServer('delete:nc:nc3-$uniqueId.wavi$firstAtSign');
      expect(response, 'data:-1');

      response =
          await firstAtSignConnection.sendRequestToServer('scan:cl $uniqueId');
      entries = jsonDecode(response.replaceAll('data:', ''));
      expect(
          entries.cast<Map>().where(
              (e) => e['atKey'] == 'nc3-$uniqueId.wavi$firstAtSign'),
          isEmpty);
    });
  });

  group('scan:cl and delete:dAt', () {
    test('scan:cl lists entries with the pinned shape, filtered by regex',
        () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:sc1-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      final commitId = int.parse(response.replaceAll('data:', ''));

      response =
          await firstAtSignConnection.sendRequestToServer('scan:cl $uniqueId');
      final List entries = jsonDecode(response.replaceAll('data:', ''));
      expect(entries.length, 1,
          reason: 'the regex confines the listing to this test\'s key');
      final Map entry = entries[0];
      expect(entry.keys.toSet(), {'atKey', 'operation', 'commitId', 'opTime'});
      expect(entry['atKey'], 'sc1-$uniqueId.wavi$firstAtSign');
      expect(entry['operation'], '*');
      expect(entry['commitId'], commitId);
      expect(entry['opTime'],
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$')));
    });

    test('delete:dAt is visible as the DELETE entry\'s opTime in scan:cl',
        () async {
      String response = await firstAtSignConnection
          .sendRequestToServer('update:sc2-$uniqueId.wavi$firstAtSign v1');
      expect(response, matches(RegExp(r'^data:\d+$')));
      response = await firstAtSignConnection.sendRequestToServer(
          'delete:dAt:$dAtWire:sc2-$uniqueId.wavi$firstAtSign');
      expect(response, matches(RegExp(r'^data:\d+$')));

      response =
          await firstAtSignConnection.sendRequestToServer('scan:cl $uniqueId');
      final List entries = jsonDecode(response.replaceAll('data:', ''));
      final Map entry = entries
          .cast<Map>()
          .firstWhere((e) => e['atKey'] == 'sc2-$uniqueId.wavi$firstAtSign');
      expect(entry['operation'], '-');
      expect(entry['opTime'], dAtWire);
    });

    test('scan:cl on an unauthenticated connection is refused', () async {
      final unauthConnection = OutboundConnectionFactory();
      await unauthConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      try {
        final response =
            await unauthConnection.sendRequestToServer('scan:cl');
        expect(response, contains('error'));
      } finally {
        await unauthConnection.close();
      }
    });

    test('scan:cl for another atSign is refused', () async {
      final response = await firstAtSignConnection
          .sendRequestToServer('scan:cl:$secondAtSign');
      expect(response, contains('error'),
          reason: 'the outbound scan proxy cannot forward :cl, so a remote '
              'commit-log scan must be refused rather than silently '
              'degrading to a plain remote scan');
    });
  });
}
