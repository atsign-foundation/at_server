import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_refresh_job.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

import 'test_utils.dart';

void main() {
  AtSignLogger.root_level = 'FINER';
  group('Cache refresh job', () {
    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('Ensure no concurrent running', () async {
      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      expect(job.running, false);
      unawaited(job.refreshNow(pauseAfterFinishing:Duration(milliseconds: 10)));
      expect(job.running, true);
      await expectLater(job.refreshNow(), throwsA(isA<StateError>()));
    });
    test('Ensure scheduled only once', () async {
      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      expect(job.running, false);
      expect(job.cron, null);
      job.scheduleRefreshJob(1);
      expect(job.cron != null, true);
      expect(() => job.scheduleRefreshJob(1), throwsA(isA<StateError>()));
    });

    test('Ensure cron stopped by close()', () async {
      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      job.scheduleRefreshJob(1);
      expect(job.cron != null, true);

      Cron? closedCron = job.close();

      expect (closedCron != null, true);
      expect(job.cron, null);

      // And if we try to schedule something on the closedCron we should get an exception
      expect(() => closedCron!.schedule(Schedule(seconds:1), () => print('hi')), throwsException);
    });

    test('Run with no records to refresh', () async {
      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      Map result = await job.refreshNow();
      expect(result['keysChecked'], 0);
      expect(result['valueUnchanged'], 0);
      expect(result['valueChanged'], 0);
      expect(result['deletedByRemote'], 0);
      expect(result['exceptionFromRemote'], 0);
    });

    test('Run with some records to refresh which have ttr > 0 not yet reached', () async {
      await createRandomKeyStoreEntry('@bob', 'cached:@alice:1.key.app@bob', secondaryKeyStore, commonsMetadata: Metadata()..ttr=1);
      await createRandomKeyStoreEntry('@bob', 'cached:@alice:2.key.app@bob', secondaryKeyStore, commonsMetadata: Metadata()..ttr=2);
      await createRandomKeyStoreEntry('@bob', 'cached:@alice:3.key.app@bob', secondaryKeyStore, commonsMetadata: Metadata()..ttr=3);
      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      Map result = await job.refreshNow();
      expect(result['keysChecked'], 0);
      expect(result['valueUnchanged'], 0);
      expect(result['valueChanged'], 0);
      expect(result['deletedByRemote'], 0);
      expect(result['exceptionFromRemote'], 0);
    });

    test('Run with some records to refresh which have ttr > 0, some ready to refresh, exception from remote', () async {
      DateTime past = DateTime.now().toUtc().subtract(Duration(seconds: 1));
      await createRandomKeyStoreEntry('@bob', 'cached:@alice:1.key.app@bob', secondaryKeyStore, commonsMetadata: Metadata()..ttr=null, refreshAt:past);
      await createRandomKeyStoreEntry('@bob', 'cached:@alice:2.key.app@bob', secondaryKeyStore, commonsMetadata: Metadata()..ttr=1);
      await createRandomKeyStoreEntry('@bob', 'cached:@alice:3.key.app@bob', secondaryKeyStore, commonsMetadata: Metadata()..ttr=null, refreshAt:past);

      List<String> toRefresh = await cacheManager.getKeyNamesToRefresh();
      expect(toRefresh.contains('cached:@alice:1.key.app@bob'), true);
      expect(toRefresh.contains('cached:@alice:2.key.app@bob'), false);
      expect(toRefresh.contains('cached:@alice:3.key.app@bob'), true);

      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      Map result = await job.refreshNow();
      print(result);
      expect(result['keysChecked'], 2);
      expect(result['valueUnchanged'], 0);
      expect(result['valueChanged'], 0);
      expect(result['deletedByRemote'], 0);
      expect(result['exceptionFromRemote'], 2);
    });

    test('Run with some records to refresh which have ttr > 0, some ready to refresh, no longer existing on remote', () async {
      DateTime past = DateTime.now().toUtc().subtract(Duration(seconds: 1));
      AtData data1 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:1.key.app@bob', secondaryKeyStore,
          data:'value 1 old', commonsMetadata: Metadata()..ttr=null, refreshAt:past);
      AtData data2 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:2.key.app@bob', secondaryKeyStore,
          data:'value 2 old', commonsMetadata: Metadata()..ttr=1);
      AtData data3 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:3.key.app@bob', secondaryKeyStore,
          data:'value 3 old', commonsMetadata: Metadata()..ttr=null, refreshAt:past);

      List<String> toRefresh = await cacheManager.getKeyNamesToRefresh();
      expect(toRefresh.contains('cached:@alice:1.key.app@bob'), true);
      expect(toRefresh.contains('cached:@alice:2.key.app@bob'), false);
      expect(toRefresh.contains('cached:@alice:3.key.app@bob'), true);

      when(() => mockOutboundConnection.write('lookup:all:1.key.app@bob\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn('error:{"errorCode":"AT0015","errorDescription":"@alice:1.key.app@bob does not exist"}\n$alice@'.codeUnits);
      });
      when(() => mockOutboundConnection.write('lookup:all:3.key.app@bob\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn('error:{"errorCode":"AT0015","errorDescription":"@alice:3.key.app@bob does not exist"}\n$alice@'.codeUnits);
      });

      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      Map result = await job.refreshNow();
      print(result);
      expect(result['keysChecked'], 2);
      expect(result['valueUnchanged'], 0);
      expect(result['valueChanged'], 0);
      expect(result['deletedByRemote'], 2);
      expect(result['exceptionFromRemote'], 0);
    });

    test('Run with some records to refresh which have ttr > 0, some ready to refresh, some not, some changed, some not',
        () async {
      DateTime past = DateTime.now().toUtc().subtract(Duration(seconds: 1));
      AtData data1 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:1.key.app@bob', secondaryKeyStore,
          data: 'value 1 old', commonsMetadata: Metadata()..ttr = null, refreshAt: past);

      AtData data2 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:2.key.app@bob', secondaryKeyStore,
          data: 'value 2 old', commonsMetadata: Metadata()..ttr = 5);

      AtData data3 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:3.key.app@bob', secondaryKeyStore,
          data: 'value 3 old', commonsMetadata: Metadata()..ttr = 1);

      AtData data4 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:4.key.app@bob', secondaryKeyStore,
          data: 'value 4 old', commonsMetadata: Metadata()..ttr = null, refreshAt: past);

      AtData data5 = await createRandomKeyStoreEntry('@bob', 'cached:@alice:5.key.app@bob', secondaryKeyStore,
          data: 'value 5 old', commonsMetadata: Metadata()..ttr = 1);

      await Future.delayed(Duration(milliseconds: 1001));

      List<String> toRefresh = await cacheManager.getKeyNamesToRefresh();
      expect(toRefresh.contains('cached:@alice:1.key.app@bob'), true); // ttr null but we set a refreshAt in the past
      expect(toRefresh.contains('cached:@alice:2.key.app@bob'), false); // ttr is 5
      expect(toRefresh.contains('cached:@alice:3.key.app@bob'), true); // ttr 1
      expect(toRefresh.contains('cached:@alice:4.key.app@bob'), true); // ttr null but we set a refreshAt in the past
      expect(toRefresh.contains('cached:@alice:5.key.app@bob'), true); // ttr 1

      // key 1 no longer exists (deleted by remote)
      when(() => mockOutboundConnection.write('lookup:all:1.key.app@bob\n')).thenAnswer((Invocation invocation) async {
        socketOnDataFn(
            'error:{"errorCode":"AT0015","errorDescription":"@alice:1.key.app@bob does not exist"}\n$alice@'.codeUnits);
      });
      // key 2 won't be checked, nothing to mock
      // key 3 value unchanged
      when(() => mockOutboundConnection.write('lookup:all:3.key.app@bob\n')).thenAnswer((Invocation invocation) async {
        var json = SecondaryUtil.prepareResponseData('all', data3, key: '@alice:3.key.app@bob')!;
        socketOnDataFn('data:$json\n$alice@'.codeUnits);
      });
      // key 4 value changed
      when(() => mockOutboundConnection.write('lookup:all:4.key.app@bob\n')).thenAnswer((Invocation invocation) async {
        data4.data = 'value 4 new';
        var json = SecondaryUtil.prepareResponseData('all', data4, key: '@alice:3.key.app@bob')!;
        socketOnDataFn('data:$json\n$alice@'.codeUnits);
      });
      // key 5 exception from remote - we'll get an exception because we're not defining a mock

      AtCacheRefreshJob job = AtCacheRefreshJob(alice, cacheManager);
      Map result = await job.refreshNow();
      print(result);
      expect(result['keysChecked'], 4);
      expect(result['valueUnchanged'], 1);
      expect(result['valueChanged'], 1);
      expect(result['deletedByRemote'], 1);
      expect(result['exceptionFromRemote'], 1);
    });
  });
}
