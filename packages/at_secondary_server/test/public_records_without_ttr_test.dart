import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_refresh_job.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_utils/at_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Scenarios: features/caching/public_records_without_ttr.feature
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

  const String enrollmentId = '0bf5a3c2-1111-4222-8333-944455556666';

  group('Looking up a public record with no ttr leaves nothing behind', () {
    for (final (String record, int? ttr, String options) in [
      ('phone.wavi$bob', null, ''),
      ('phone.wavi$bob', 0, ''),
      ('__nskey.app$bob', null, ''),
      ('__nskey.app$bob', null, 'bypassCache:true:'),
      ('_apsk.$enrollmentId.a.__e$bob', null, ''),
      ('_apsk.$enrollmentId.r.__e$bob', null, ''),
      ('_apsk.$enrollmentId.d.__e$bob', null, ''),
    ]) {
      test('plookup:${options}all:$record with ttr $ttr', () async {
        final String cached = 'cached:public:$record';
        bobAnswers(record, bobsRecord('bobs value', ttr: ttr));
        expect(await keyValueStore.exists(cached), false);

        await plookup.process(
            'plookup:${options}all:$record', inboundConnection);

        expect(decodeResponse(inboundConnection.lastWrittenData!)['data'],
            'bobs value');
        expect(await keyValueStore.exists(cached), false,
            reason: 'a record with no ttr is not copied');
        expect(atCommitLog.getLatestCommitEntry(cached), isNull,
            reason: 'nothing about it is committed, so nothing syncs down');
      });
    }
  });

  test('A record with a ttr is still copied, and served within it', () async {
    final String record = 'phone.wavi$bob';
    final String cached = 'cached:public:$record';
    bobAnswers(record, bobsRecord('bobs value', ttr: 3600));

    await plookup.process('plookup:all:$record', inboundConnection);
    final AtData? copy = await keyValueStore.get(cached);
    expect(copy?.metaData?.ttr, 3600);

    await plookup.process('plookup:all:$record', inboundConnection);
    final Map served = decodeResponse(inboundConnection.lastWrittenData!);
    expect(served['data'], 'bobs value');
    expect(served['key'], cached,
        reason: 'the second plookup is answered from the copy');
    verify(() => mockOutboundConnection.write('lookup:all:$record\n'))
        .called(1);
  });

  test('Another atSign\'s encryption public key is still kept indefinitely',
      () async {
    bobAnswers('publickey$bob', bobsRecord('bobs public key'));

    await plookup.process('plookup:all:publickey$bob', inboundConnection);

    final AtData? copy = await keyValueStore.get(cachedBobsPublicKeyName);
    expect(copy?.metaData?.ttr, -1);
  });

  group('A leftover copy goes the next time the record is looked up', () {
    for (final String record in [
      'phone.wavi$bob',
      '__nskey.app$bob',
      '_apsk.$enrollmentId.a.__e$bob',
    ]) {
      test('plookup:all:$record', () async {
        final String cached = 'cached:public:$record';
        await keyValueStore.put(
            cached,
            AtData()
              ..data = 'left over'
              ..metaData = (AtMetaData()..ttl = 24 * 60 * 60 * 1000));
        bobAnswers(record, bobsRecord('bobs current value'));

        await plookup.process('plookup:all:$record', inboundConnection);

        expect(decodeResponse(inboundConnection.lastWrittenData!)['data'],
            'bobs current value');
        expect(await keyValueStore.exists(cached), false);
        expect(atCommitLog.getLatestCommitEntry(cached)?.operation,
            CommitOp.DELETE,
            reason: 'the removal is committed, so clients drop their copy');
      });
    }
  });

  test('The nightly refresh removes a leftover nobody looks up', () async {
    final String record = 'phone.wavi$bob';
    final String cached = 'cached:public:$record';
    await keyValueStore.put(cached, AtData()..data = 'left over');
    expect(await cacheManager.getKeyNamesToRefresh(), contains(cached),
        reason: 'the refresh has to reach the leftover for this to mean '
            'anything');
    bobAnswers(record, bobsRecord('bobs current value'));

    await AtCacheRefreshJob(alice, cacheManager).refreshNow();

    expect(await keyValueStore.exists(cached), false);
    expect(atCommitLog.getLatestCommitEntry(cached)?.operation,
        CommitOp.DELETE);
    verifyNever(() => mockOutboundConnection.write('lookup:all:$record\n'));
  });

  group('The nightly refresh leaves a shared copy alone', () {
    const String cached = 'cached:@alice:phone@bob';

    void bobSharesNow(String value) {
      when(() => mockOutboundConnection.write('lookup:all:phone$bob\n'))
          .thenAnswer((_) async {
        final String json = SecondaryUtil.prepareResponseData(
            'all', bobsRecord(value),
            key: '$alice:phone$bob')!;
        socketOnDataFn('data:$json\n$alice@'.codeUnits);
      });
    }

    test('a changed value is written, as before', () async {
      await keyValueStore.put(cached, AtData()..data = 'shared before');
      bobSharesNow('shared now');

      await AtCacheRefreshJob(alice, cacheManager).refreshNow();

      expect((await keyValueStore.get(cached))?.data, 'shared now',
          reason: 'a shared copy is refreshed as before, not deleted');
    });

    test('an unchanged value with no ttr is not written', () async {
      await keyValueStore.put(cached, AtData()..data = 'shared same');
      final int? before = atCommitLog.getLatestCommitEntry(cached)?.commitId;
      bobSharesNow('shared same');

      await AtCacheRefreshJob(alice, cacheManager).refreshNow();

      expect((await keyValueStore.get(cached))?.data, 'shared same');
      expect(atCommitLog.getLatestCommitEntry(cached)?.commitId, before,
          reason: 'a copy with no ttr is never served, so re-writing it '
              'would only commit it again every night');
    });
  });
}
