import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/stats_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  for (final backend in AtPersistenceBackendId.values) {
    group('${backend.name}:', () {
      setUp(() async {
        await verbTestsSetUp(backend: backend);
      });

      tearDown(() async {
        await verbTestsTearDown();
      });

      lastCommitIdThroughTheVerbHandler();
      lastCommitIdCountsWhatSyncSends();
    });
  }
}

void lastCommitIdThroughTheVerbHandler() {
  group('stats:3 through the verb handler', () {
    /// The lastCommitID that `stats:3`, filtered by [regex] when given,
    /// answers on a CRAM connection, which has no enrollment.
    Future<String> lastCommitIdFromVerb([String? regex]) async {
      inboundConnection.metadata
        ..isAuthenticated = true
        ..authType = AuthType.cram;
      final response = await StatsVerbHandler(keyValueStore).processInternal(
          regex == null ? 'stats:3' : 'stats:3:$regex', inboundConnection);
      return (jsonDecode(response.data!) as List).single['value'];
    }

    /// Writes two keys, then rewrites the second with no commit, which
    /// purges the newest entry. Returns the id the second key was issued.
    Future<int> purgeNewest() async {
      await keyValueStore.put('$alice:phone.wavi$alice', AtData()..data = '1');
      final purgedId = (await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = '2'))!;
      await keyValueStore.put(
          '$alice:location.wavi$alice', AtData()..data = '3',
          skipCommit: true);
      return purgedId;
    }

    test('an unfiltered request reports the last commit id after a purge',
        () async {
      final purgedId = await purgeNewest();
      expect(await lastCommitIdFromVerb(), '$purgedId',
          reason: 'a client may already hold the purged id, and compares it '
              'with this answer');
      expect(await lastCommitIdFromVerb('.*'), '$purgedId',
          reason: 'an explicit .* admits every key, as no regex does');
    });

    test('a filtered request reports the highest id it admits', () async {
      final purgedId = await purgeNewest();
      expect(await lastCommitIdFromVerb('wavi'), '${purgedId - 1}',
          reason: 'a filtered request answers from the entries it admits');
    });

    test('an unfiltered request on an empty log reports -1', () async {
      expect(await lastCommitIdFromVerb(), '-1');
    });
  });
}

void lastCommitIdCountsWhatSyncSends() {
  group('stats:3 counts by the rule sync:from sends by', () {
    /// Enrols [connection] with [namespaces] and returns its enrollment id.
    Future<String> enrolWith(DummyInboundConnection connection,
        Map<String, String> namespaces) async {
      final String enrollmentId = Uuid().v4();
      await keyValueStore.put(
          '$enrollmentId.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': namespaces,
              'apkamPublicKey': 'testPublicKeyValue',
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'}
            }),
          skipCommit: true);
      connection.metadata
        ..isAuthenticated = true
        ..authType = AuthType.apkam
        ..enrollmentId = enrollmentId;
      return enrollmentId;
    }

    /// What `stats:3`, with [regex] when given, answers on [connection].
    Future<String> statsLastCommitId(DummyInboundConnection connection,
        {String? regex, StatsVerbHandler? handler}) async {
      final response = Response();
      await (handler ?? StatsVerbHandler(keyValueStore)).processVerb(
          response,
          HashMap.of({
            AtConstants.statId: '3',
            if (regex != null) AtConstants.regex: regex,
          }),
          connection);
      return (jsonDecode(response.data!) as List).single['value'];
    }

    /// The highest commit id `sync:from`, with [regex] when given, sends
    /// [connection], or `'null'` when it sends nothing.
    Future<String> syncedLastCommitId(DummyInboundConnection connection,
        {String? regex}) async {
      final response = Response();
      await SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog)
          .processVerb(
              response,
              HashMap.of({
                AtConstants.fromCommitSequence: '-1',
                AtConstants.syncLimit: '100',
                if (regex != null) 'regex': regex,
              }),
              connection);
      final ids = [
        for (final entry in jsonDecode(response.data!) as List)
          entry['commitId'] as int
      ];
      return ids.isEmpty ? 'null' : '${ids.reduce(max)}';
    }

    /// Writes [key] and returns the commit id it was issued.
    Future<int> put(String key) async =>
        (await keyValueStore.put(key, AtData()..data = 'v'))!;

    test('an enrollment counts its own namespace', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      await put('$alice:phone.wavi$alice');
      final locationId = await put('$alice:location.wavi$alice');
      await put('$alice:mobile.buzz$alice');
      expect(await statsLastCommitId(connection), '$locationId');
      expect(await syncedLastCommitId(connection), '$locationId');
    });

    test('an enrollment counts every namespace it holds', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw', 'buzz': 'rw'});
      await put('$alice:phone.wavi$alice');
      await put('$alice:location.wavi$alice');
      final mobileId = await put('$alice:mobile.buzz$alice');
      await put('$alice:contact.atmosphere$alice');
      expect(await statsLastCommitId(connection), '$mobileId');
      expect(await syncedLastCommitId(connection), '$mobileId');
    });

    test('a CRAM connection\'s regex filters the count', () async {
      final connection = DummyInboundConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.cram;
      await put('$alice:phone.wavi$alice');
      await put('$alice:location.wavi$alice');
      final mobileId = await put('$alice:mobile.buzz$alice');
      await put('$alice:contact.atmosphere$alice');
      expect(await statsLastCommitId(connection, regex: 'buzz'), '$mobileId');
      expect(await syncedLastCommitId(connection, regex: 'buzz'), '$mobileId');
    });

    test('an enrollment holding * is unfiltered', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'*': 'rw', '__manage': 'rw'});
      await put('phone.wavi$alice');
      final purgedId = (await keyValueStore.put(
          'location.wavi$alice', AtData()..data = 'v'))!;
      await keyValueStore.put('location.wavi$alice', AtData()..data = 'v2',
          skipCommit: true);
      expect(await statsLastCommitId(connection), '$purgedId',
          reason: 'an enrollment holding * filters nothing, so it gets the '
              'last commit id issued, which a purge does not lower');
    });

    test('an enrollment\'s own reserved-namespace key is counted', () async {
      final connection = DummyInboundConnection();
      final enrollmentId = await enrolWith(connection, {'wavi': 'rw'});
      await put('phone.wavi$alice');
      final reservedId = await put('__ckcur.bob.wavi.'
          '${AbstractVerbHandler.enrollmentReservedNamespace(enrollmentId)}'
          '$alice');
      expect(await syncedLastCommitId(connection), '$reservedId',
          reason: 'control: sync:from must send the entry this test is about');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'sync:from sends an enrollment its own .a.__e keys');
    });

    test('an __atserver key is counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      await put('phone.wavi$alice');
      final atServerKeyId = await put('config.__atserver$alice');
      expect(await syncedLastCommitId(connection), '$atServerKeyId',
          reason: 'control: sync:from must send the entry this test is about');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'every enrollment reads the __atserver namespace');
    });

    test('a multi-segment enrolled namespace is counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'chat.wavi': 'rw'});
      final messageId = await put('msg1.chat.wavi$alice');
      expect(await syncedLastCommitId(connection), '$messageId',
          reason: 'control: sync:from must send the entry this test is about');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'sync:from matches chat.wavi against the whole key');
    });

    test('a __manage key is not counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw', '__manage': 'rw'});
      final phoneId = await put('phone.wavi$alice');
      final manageKey = '${Uuid().v4()}.new.enrollments.__manage$alice';
      await keyValueStore.put(manageKey, AtData()..data = '{}',
          skipCommit: true);
      await atCommitLog.commit(manageKey, CommitOp.UPDATE);
      expect(await syncedLastCommitId(connection), '$phoneId',
          reason: 'control: sync:from must send the entry this test is about');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'sync:from never sends a __manage key');
    });

    test('a configkey entry neither breaks the count nor is counted', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      final phoneId = await put('phone.wavi$alice');
      await keyValueStore.put('configkey', AtData()..data = '[]');
      expect(atCommitLog.getLatestCommitEntry('configkey'), isNotNull,
          reason: 'the blocklist key must be in the commit log for this test');
      expect(await syncedLastCommitId(connection), '$phoneId',
          reason: 'control: sync:from must send the entry this test is about');
      expect(await statsLastCommitId(connection),
          await syncedLastCommitId(connection),
          reason: 'configkey is not a well-formed atKey (#1570), and sync:from '
              'skips it');
    });

    test('an admitted entry below many others is still found', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      final admittedId = await put('phone.wavi$alice');
      for (var i = 0; i < 1200; i++) {
        await put('x$i.buzz$alice');
      }
      expect(await syncedLastCommitId(connection), '$admittedId');
      expect(await statsLastCommitId(connection), '$admittedId',
          reason: 'the newest admitted entry sits below more than one window '
              'of entries this enrollment is not sent');
    });

    test('a log with nothing admitted answers null', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'wavi': 'rw'});
      final ids = [for (var i = 0; i < 600; i++) await put('x$i.buzz$alice')];
      expect(ids.toSet(), hasLength(600),
          reason: 'the log must hold the entries this test is about');
      expect(await syncedLastCommitId(connection), 'null');
      expect(await statsLastCommitId(connection), 'null');
    });

    test('a regex filters the count as it filters sync:from', () async {
      final connection = DummyInboundConnection();
      await enrolWith(connection, {'*': 'rw'});
      final phoneId = await put('phone.wavi$alice');
      await put('mobile.buzz$alice');
      expect(await syncedLastCommitId(connection, regex: 'wavi'), '$phoneId',
          reason: 'control: sync:from must send the entry this test is about');
      expect(await statsLastCommitId(connection, regex: 'wavi'),
          await syncedLastCommitId(connection, regex: 'wavi'));
    });

    test('concurrent requests each answer for their own regex', () async {
      final phoneId = await put('phone.wavi$alice');
      final mobileId = await put('mobile.buzz$alice');
      final enrolled = DummyInboundConnection();
      await enrolWith(enrolled, {'*': 'rw'});
      final cram = DummyInboundConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.cram;
      final handler = StatsVerbHandler(keyValueStore);
      final answers = await Future.wait([
        statsLastCommitId(enrolled, regex: 'wavi', handler: handler),
        statsLastCommitId(cram, regex: 'buzz', handler: handler),
      ]);
      expect(answers, ['$phoneId', '$mobileId'],
          reason: 'one handler serves every connection, so a request must not '
              'read another request\'s regex');
    });
  });
}
