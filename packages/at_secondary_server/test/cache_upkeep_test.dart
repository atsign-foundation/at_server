import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_refresh_job.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_utils/at_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Scenarios: features/caching/cache_upkeep.feature
void main() {
  AtSignLogger.root_level = 'WARNING';

  late ProxyLookupVerbHandler plookup;

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
    plookup = ProxyLookupVerbHandler(
        keyValueStore, mockOutboundClientManager, cacheManager,
        accessLog: atAccessLog);
    inboundConnection.metadata.isAuthenticated = true;
    inboundConnection.metadata.authType = AuthType.cram;
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  AtData bobsRecord(String value, {int? ttr}) {
    final DateTime now = DateTime.now().toUtc();
    return AtData()
      ..data = value
      ..metaData = (AtMetaData()
        ..createdAt = now
        ..updatedAt = now
        ..ttr = ttr);
  }

  void bobAnswers(String record, AtData atData) {
    final String json = SecondaryUtil.prepareResponseData('all', atData,
        key: 'public:$record')!;
    when(() => mockOutboundConnection.write('lookup:all:$record\n'))
        .thenAnswer((_) async {
      socketOnDataFn('data:$json\n$alice@'.codeUnits);
    });
  }

  void bobHasNo(String record) {
    when(() => mockOutboundConnection.write('lookup:all:$record\n'))
        .thenAnswer((_) async {
      socketOnDataFn(
          'error:{"errorCode":"AT0015","errorDescription":"$record does not exist"}\n$alice@'
              .codeUnits);
    });
  }

  group(
      'Looking up a record that does not exist commits nothing when no copy is held',
      () {
    test('plookup:all:email.wavi@bob', () async {
      final String record = 'email.wavi$bob';
      final String cached = 'cached:public:$record';
      bobHasNo(record);

      await expectLater(plookup.process('plookup:all:$record', inboundConnection),
          throwsA(isA<KeyNotFoundException>()));

      expect(atCommitLog.getLatestCommitEntry(cached), isNull,
          reason: 'there was no copy, so there is no DELETE to commit');
    });

    test('a shared record\'s copy, looked up by alice\'s atServer', () async {
      final String cached = 'cached:$alice:phone$bob';
      when(() => mockOutboundConnection.write('lookup:all:phone$bob\n'))
          .thenAnswer((_) async {
        socketOnDataFn(
            'error:{"errorCode":"AT0015","errorDescription":"$alice:phone$bob does not exist"}\n$alice@'
                .codeUnits);
      });

      await expectLater(
          cacheManager.remoteLookUp(cached, maintainCache: true),
          throwsA(isA<KeyNotFoundException>()));

      expect(atCommitLog.getLatestCommitEntry(cached), isNull);
    });
  });

  test('Looking up a record that no longer exists deletes the copy held',
      () async {
    final String record = 'email.wavi$bob';
    final String cached = 'cached:public:$record';
    bobAnswers(record, bobsRecord('bobs value', ttr: 1));
    await plookup.process('plookup:all:$record', inboundConnection);
    expect(await keyValueStore.exists(cached), true);
    await Future.delayed(const Duration(milliseconds: 1100));
    bobHasNo(record);

    await expectLater(plookup.process('plookup:all:$record', inboundConnection),
        throwsA(isA<KeyNotFoundException>()));

    expect(await keyValueStore.exists(cached), false);
    expect(atCommitLog.getLatestCommitEntry(cached)?.operation, CommitOp.DELETE,
        reason: 'the DELETE is committed, so alice\'s clients drop it too');
  });

  test('A refresh that finds the value unchanged keeps the copy servable',
      () async {
    // ttr 3 stands in for the scenario's 3600: the keystore derives refreshAt
    // from the ttr, so a copy is only past its refreshAt once that much time
    // has gone.
    final String record = 'phone.wavi$bob';
    final String cached = 'cached:public:$record';
    bobAnswers(record, bobsRecord('bobs value', ttr: 3));
    await plookup.process('plookup:all:$record', inboundConnection);
    await Future.delayed(const Duration(milliseconds: 3100));
    expect(await cacheManager.get(cached, applyMetadataRules: true), isNull,
        reason: 'the copy has to be past its refreshAt before the refresh');
    final int? committedBefore = atCommitLog.getLatestCommitEntry(cached)?.commitId;

    await AtCacheRefreshJob(alice, cacheManager).refreshNow();

    final AtData? copy = await keyValueStore.get(cached);
    expect(copy?.metaData?.refreshAt?.isAfter(DateTime.now().toUtc()), true,
        reason: 'the refreshAt moves a ttr on');
    await plookup.process('plookup:all:$record', inboundConnection);
    expect(decodeResponse(inboundConnection.lastWrittenData!)['key'], cached,
        reason: 'the next plookup is answered from the copy');
    verify(() => mockOutboundConnection.write('lookup:all:$record\n'))
        .called(2);
    final CommitEntry? committed = atCommitLog.getLatestCommitEntry(cached);
    expect(committed?.operation, CommitOp.UPDATE_ALL);
    expect(committed?.commitId, greaterThan(committedBefore!),
        reason: 'the re-written copy is committed, as a lookup\'s re-write is');
  });
}
