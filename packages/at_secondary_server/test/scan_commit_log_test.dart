// scan:cl — the commit-log scan from the at_commons 5.10.0 protocol
// enhancements: an authenticated client lists commit-log entries (to judge
// cruft, then delete:nc it), filtered exactly as a keystore scan is —
// regex, hidden-key rules, enrollment namespaces.
//
// Isolation: per-test, via verbTestsSetUp/verbTestsTearDown.

import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:test/test.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;

import 'test_utils.dart';

void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  late ScanVerbHandler scanHandler;
  late UpdateVerbHandler updateHandler;
  late DeleteVerbHandler deleteHandler;

  setUp(() async {
    await verbTestsSetUp();
    scanHandler =
        ScanVerbHandler(keyValueStore, mockOutboundClientManager, cacheManager);
    updateHandler = UpdateVerbHandler(
        keyValueStore, statsNotificationService, notificationManager, alice);
    deleteHandler = DeleteVerbHandler(
        keyValueStore, statsNotificationService, notificationManager);
    inboundConnection.metadata.isAuthenticated = true;
    inboundConnection.metadata.authType = AuthType.cram;
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  Future<List> scanCl([String suffix = '']) async {
    await scanHandler.process('scan:cl$suffix', inboundConnection);
    final data = inboundConnection.lastWrittenData!
        .split('\n')[0]
        .replaceAll('data:', '');
    return jsonDecode(data) as List;
  }

  group('scan:cl basics', () {
    test('returns entries in ascending commitId order with the pinned '
        'shape', () async {
      await updateHandler.process(
          'update:phone.wavi$alice 12345', inboundConnection);
      await updateHandler.process(
          'update:email.wavi$alice a@b.c', inboundConnection);

      final entries = await scanCl();
      expect(entries.length, 2);
      final first = entries[0] as Map;
      final second = entries[1] as Map;
      // Shape pin: this is a new client-facing wire contract.
      expect(first.keys.toSet(), {'atKey', 'operation', 'commitId', 'opTime'});
      expect(first['atKey'], 'phone.wavi$alice');
      expect(first['operation'], '*',
          reason: 'a handler-driven update commits as UPDATE_ALL — the '
              'same symbol vocabulary sync emits');
      expect(first['commitId'], isA<int>());
      expect(
          first['opTime'],
          matches(RegExp(
              r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$')),
          reason: 'opTime uses the same ISO 8601 UTC vocabulary as the '
              'wire timestamps');
      expect(second['atKey'], 'email.wavi$alice');
      expect((second['commitId'] as int) > (first['commitId'] as int), isTrue,
          reason: 'entries are ordered by ascending commitId');
    });

    test('a DELETE entry appears, carrying the asserted dAt as its opTime',
        () async {
      await updateHandler.process(
          'update:phone.wavi$alice 12345', inboundConnection);
      await deleteHandler.process(
          'delete:dAt:2023-05-05T11:59:44.123000Z:phone.wavi$alice',
          inboundConnection);

      final entries = await scanCl();
      final deleteEntry = entries
          .cast<Map>()
          .firstWhere((e) => e['atKey'] == 'phone.wavi$alice');
      expect(deleteEntry['operation'], '-',
          reason: 'a DELETE entry for a key that no longer exists is '
              'exactly what cruft management is looking for');
      expect(deleteEntry['opTime'], '2023-05-05T11:59:44.123000Z');
    });

    test('after update:nc, the key\'s entry is gone from scan:cl', () async {
      await updateHandler.process(
          'update:phone.wavi$alice 12345', inboundConnection);
      expect((await scanCl()).cast<Map>()
          .where((e) => e['atKey'] == 'phone.wavi$alice'), isNotEmpty);

      await updateHandler.process(
          'update:nc:phone.wavi$alice 6789', inboundConnection);
      expect((await scanCl()).cast<Map>()
          .where((e) => e['atKey'] == 'phone.wavi$alice'), isEmpty);
    });

    test('regex filters entries by atKey', () async {
      await updateHandler.process(
          'update:phone.wavi$alice 12345', inboundConnection);
      await updateHandler.process(
          'update:mobile.buzz$alice 999', inboundConnection);

      final entries = await scanCl(' .wavi');
      expect(entries.cast<Map>().map((e) => e['atKey']),
          contains('phone.wavi$alice'));
      expect(entries.cast<Map>().map((e) => e['atKey']),
          isNot(contains('mobile.buzz$alice')));
    });

    test('hidden keys are excluded unless showhidden:true', () async {
      // public:__ keys ARE synced, so they have commit entries.
      await keyValueStore.put(
          'public:__hidden.wavi$alice', AtData()..data = 'h');
      await updateHandler.process(
          'update:phone.wavi$alice 12345', inboundConnection);

      var keys =
          (await scanCl()).cast<Map>().map((e) => e['atKey']).toList();
      expect(keys, isNot(contains('public:__hidden.wavi$alice')));

      keys = (await scanCl(':showhidden:true'))
          .cast<Map>()
          .map((e) => e['atKey'])
          .toList();
      expect(keys, contains('public:__hidden.wavi$alice'));
    });
  });

  group('scan:cl refusals', () {
    test('unauthenticated connection is refused', () async {
      inboundConnection.metadata.isAuthenticated = false;
      await expectLater(
          scanHandler.process('scan:cl', inboundConnection),
          throwsA(isA<UnAuthenticatedException>()));
    });

    test('scan:cl for another atSign is refused loudly', () async {
      // The outbound scan proxy cannot forward :cl — silently degrading
      // to a plain remote scan would return keystore keys labelled as
      // commit-log entries.
      await expectLater(
          scanHandler.process('scan:cl:@bob', inboundConnection),
          throwsA(isA<InvalidRequestException>()));
    });
  });

  group('scan:cl APKAM enrollment filtering', () {
    test('an enrollment sees only entries in its authorized namespaces',
        () async {
      await updateHandler.process(
          'update:firstname.wavi$alice alice', inboundConnection);
      await updateHandler.process(
          'update:mobile.buzz$alice +1 434', inboundConnection);
      await updateHandler.process(
          'update:public:city.wavi$alice tokyo', inboundConnection);

      final enrollmentId =
          await createAndPersistAnEnrollment('wavi', 'pixel', {'wavi': 'r'});
      inboundConnection.metadata.sessionID = 'dummy_session';
      inboundConnection.metadata.enrollmentId = enrollmentId;
      inboundConnection.metadata.authType = AuthType.apkam;

      final keys =
          (await scanCl()).cast<Map>().map((e) => e['atKey']).toList();
      expect(keys, contains('firstname.wavi$alice'));
      expect(keys, contains('public:city.wavi$alice'),
          reason: 'public keys stay visible to any enrollment');
      expect(keys, isNot(contains('mobile.buzz$alice')),
          reason: 'entries outside the enrolled namespaces are filtered');
    });

    test('a *:rw enrollment sees all namespaces but not enrollment keys',
        () async {
      await updateHandler.process(
          'update:firstname.wavi$alice alice', inboundConnection);
      await updateHandler.process(
          'update:mobile.buzz$alice +1 434', inboundConnection);
      // An enrollment record committed to the log (unlike the harness's
      // skipCommit-written ones) must still be invisible to '*'.
      await keyValueStore.put('deadbeef.new.enrollments.__manage$alice',
          AtData()..data = '{"appName":"x"}');

      final enrollmentId =
          await createAndPersistAnEnrollment('wavi', 'pixel', {'*': 'rw'});
      inboundConnection.metadata.sessionID = 'dummy_session';
      inboundConnection.metadata.enrollmentId = enrollmentId;
      inboundConnection.metadata.authType = AuthType.apkam;

      final keys =
          (await scanCl()).cast<Map>().map((e) => e['atKey']).toList();
      expect(keys, contains('firstname.wavi$alice'));
      expect(keys, contains('mobile.buzz$alice'));
      expect(keys, isNot(contains('deadbeef.new.enrollments.__manage$alice')));
    });

    test('an enrollment with no namespaces sees nothing', () async {
      await updateHandler.process(
          'update:firstname.wavi$alice alice', inboundConnection);

      final enrollmentId = await createAndPersistAnEnrollment(
          'wavi', 'pixel', <String, String>{});
      inboundConnection.metadata.sessionID = 'dummy_session';
      inboundConnection.metadata.enrollmentId = enrollmentId;
      inboundConnection.metadata.authType = AuthType.apkam;

      expect(await scanCl(), isEmpty);
    });
  });
}
