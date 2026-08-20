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
      final soon = VerbUtil.formatIso8601Micros(
          DateTime.now().toUtc().add(Duration(seconds: 3)));
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:eAt:$soon:ts4-$uniqueId.wavi$firstAtSign fleeting');
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
