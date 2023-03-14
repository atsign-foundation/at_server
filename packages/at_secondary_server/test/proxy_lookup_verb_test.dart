import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';
import 'package:mocktail/mocktail.dart';
import 'test_utils.dart';

void main() {
  AtSignLogger.root_level = 'WARNING';

  try {
    group('plookup (proxy lookup) behaviour tests', () {
      /// Test the actual behaviour of the proxy lookup (plookup) verb handler.
      /// (Syntax tests are covered in the next test group, 'proxy lookup syntax tests')
      ///
      /// plookup requires authenticated connection from owner and does the following
      /// * Checks if we have a cached copy
      /// * If not, or if the cached copy is due a refresh, or if bypassCache is requested,
      ///   then do a remote lookup and cache the response according to caching rules
      /// * The caching rules are
      ///   * If ttr is -1, cache indefinitely, refresh not required. There are very few actual
      ///     use cases for this - the most important is the encryption public key `publickey@atsign`
      ///     of another atSign
      ///   * If ttr is greater than zero, then the intent is to invalidate the cache for this record
      ///     every ttr seconds
      ///   * If ttr is null or 0, then the record should not be cacheable. HOWEVER!
      ///     * For historical reasons, we have ended up caching data even if the ttr is null or zero
      ///       1) for other atSign's public encryption keys. These should actually be created with ttr
      ///          of -1 anyway, so we will explicitly set ttr to -1 for matching keys (public:publickey@atSign)
      ///       2) for any public keys, we were explicitly setting ttr to -1. This is strictly incorrect.
      ///          From now on, we will keep ttr as null, but will set a **ttl** of 24 hours on the cached value.
      ///          i.e. we will not automatically refresh the cache; rather, the item in the cache will expire
      ///          and be deleted after 24 hours. A subsequent plookup will result in a remote lookup.
      ///          This seems a reasonable compromise between the old definitely incorrect behaviour where
      ///          all public data was cached indefinitely, versus immediately starting to strictly enforce
      ///          the caching rules as intended, likely impacting existing applications' performance.
      ///
      /// This test group tests all of the above behaviour
      ///
      /// We are using the concrete implementation of the SecondaryKeyStore in these tests as we
      /// don't need to mock its behaviour.

      late ProxyLookupVerbHandler plookupVerbHandler;

      setUpAll(() async {
        await verbTestsSetUpAll();
      });

      setUp(() async {
        await verbTestsSetUp();
        plookupVerbHandler = ProxyLookupVerbHandler(secondaryKeyStore, mockOutboundClientManager, cacheManager);
      });

      tearDown(() async {
        await verbTestsTearDown();
      });

      var keyName = 'first_name.wavi$bob';
      var cachedKeyName = 'cached:public:$keyName';

      test('plookup - do nothing except trigger first run of setUp()', () async {});

      test('plookup - not in cache and does not exist on remote', () async {
        inboundConnection.getMetaData().isAuthenticated = true; // owner connection, authenticated

        when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
            .thenAnswer((Invocation invocation) async {
          socketOnDataFn('error:{"errorCode":"AT0015","errorDescription":"$keyName does not exist"}\n$alice@'.codeUnits);
        });
        await expectLater(plookupVerbHandler.process('plookup:all:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));
      });

      // To test various flavours of ttr without repeating a ton of code for each one
      Future<void> lookupAndCache({required int? ttr, required bool expectDifferentMetadata, required int? expectedTtl, required int? expectedTtr}) async {
        AtData bobData = createRandomAtData(bob);
        bobData.metaData!.ttr = ttr;
        bobData.metaData!.ttb = null;
        bobData.metaData!.ttl = null;
        String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: 'public:$keyName')!;

        inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

        // The plookup will make an unauthenticated lookup request to the other atServer
        when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
            .thenAnswer((Invocation invocation) async {
          socketOnDataFn("data:$bobDataAsJsonWithKey\n@".codeUnits);
        });

        await plookupVerbHandler.process('plookup:all:$keyName', inboundConnection);

        // Even if the ttr is null or zero, our compromise rules for now are that
        // we will cache the record, keep ttr as null (or zero), but assign a ttl of 24 hours
        expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
        // Cached data should be identical to what was sent by @bob
        AtData cachedAtData = (await secondaryKeyStore.get(cachedKeyName))!;
        expect(cachedAtData.data, bobData.data);
        // The metadata should NOT match, as we have set a ttl
        if (expectDifferentMetadata) {
          expect(cachedAtData.metaData!.toCommonsMetadata() == bobData.metaData!.toCommonsMetadata(), false);
          // But if we then set the ttl and/or ttr on the original metaData, the metadata should match exactly
          bobData.metaData!.ttl = expectedTtl;
          bobData.metaData!.ttr = expectedTtr;
        }
        expect(cachedAtData.metaData!.toCommonsMetadata(), bobData.metaData!.toCommonsMetadata());
        expect(cachedAtData.key, cachedKeyName);

        // First plookup:all (when it's not in the cache) will have 'key' in the response of e.g. public:first_name.wavi@bob
        Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
        expect(mapSentToClient['data'], bobData.data);
        expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
            bobData.metaData!.toCommonsMetadata());
        expect(mapSentToClient['key'], 'public:$keyName');

        expect(secondaryKeyStore.isKeyExists(keyName), false);
        expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      }

      test('plookup - not in cache but exists on remote - ttr null', () async {
        await lookupAndCache(ttr:null, expectDifferentMetadata:true, expectedTtl:24 * 60 * 60 * 1000, expectedTtr:null);
      });
      test('plookup - not in cache but exists on remote - ttr 0', () async {
        await lookupAndCache(ttr:0, expectDifferentMetadata:true, expectedTtl:24 * 60 * 60 * 1000, expectedTtr:0);
      });
      test('plookup - not in cache but exists on remote - ttr 10', () async {
        await lookupAndCache(ttr:10, expectDifferentMetadata:false, expectedTtl:null, expectedTtr:10);
      });
      test('plookup - not in cache but exists on remote - ttr -1', () async {
        await lookupAndCache(ttr:-1, expectDifferentMetadata:false, expectedTtl:null, expectedTtr:-1);
      });

      test('plookup - in cache and valid', () async {
        AtData bobData = createRandomAtData(bob);
        bobData.metaData!.ttr = 3600; // one hour
        bobData.metaData!.ttb = null;
        bobData.metaData!.ttl = null;
        await cacheManager.put(cachedKeyName, bobData);
        expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);

        inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

        await plookupVerbHandler.process('plookup:all:$keyName', inboundConnection);

        // plookup:all when there is a cache hit will have 'key' like e.g. cached:public:first_name.wavi@bob
        Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
        expect(mapSentToClient['data'], bobData.data);
        expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
            bobData.metaData!.toCommonsMetadata());
        expect(mapSentToClient['key'], 'cached:public:$keyName');
      });

      test('plookup - in cache and valid, but bypassCache requested', () async {
        AtData bobOriginalData = createRandomAtData(bob);
        bobOriginalData.data = "Old data";
        bobOriginalData.metaData!.ttr = 3600; // one hour
        bobOriginalData.metaData!.ttb = null;
        bobOriginalData.metaData!.ttl = null;
        await cacheManager.put(cachedKeyName, bobOriginalData);
        expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);

        AtData bobNewData = AtData().fromJson(bobOriginalData.toJson());
        bobNewData.data = "New data";
        bobOriginalData.metaData!.ttr = 60; // 1 minute, just to distinguish
        String bobNewDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobNewData, key: 'public:$keyName')!;

        inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

        when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
            .thenAnswer((Invocation invocation) async {
          socketOnDataFn("data:$bobNewDataAsJsonWithKey\n@".codeUnits);
        });

        verifyNever(() => mockOutboundConnection.write('lookup:all:$keyName\n'));
        await plookupVerbHandler.process('plookup:bypassCache:true:all:$keyName', inboundConnection);
        verify(() => mockOutboundConnection.write('lookup:all:$keyName\n')).called(1);

        Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
        expect(mapSentToClient['data'], bobNewData.data);
        expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
            bobNewData.metaData!.toCommonsMetadata());
        expect(mapSentToClient['key'], 'public:$keyName');
      });

      test('plookup - in cache but requires refresh', () async {
        AtData bobOriginalData = createRandomAtData(bob);
        bobOriginalData.data = "Old data";
        bobOriginalData.metaData!.ttr = 1; // one second
        bobOriginalData.metaData!.ttb = null;
        bobOriginalData.metaData!.ttl = null;
        await cacheManager.put(cachedKeyName, bobOriginalData);
        expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);

        AtData bobNewData = AtData().fromJson(bobOriginalData.toJson());
        bobNewData.data = "New data";
        bobOriginalData.metaData!.ttr = 60; // 2 seconds, just to be different from original
        String bobNewDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobNewData, key: 'public:$keyName')!;

        inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

        await Future.delayed(Duration(seconds: 1)); // Wait for a second so that it's time to refresh
        when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
            .thenAnswer((Invocation invocation) async {
          socketOnDataFn("data:$bobNewDataAsJsonWithKey\n@".codeUnits);
        });

        verifyNever(() => mockOutboundConnection.write('lookup:all:$keyName\n'));
        await plookupVerbHandler.process('plookup:all:$keyName', inboundConnection);
        verify(() => mockOutboundConnection.write('lookup:all:$keyName\n')).called(1);

        Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
        expect(mapSentToClient['data'], bobNewData.data);
        expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
            bobNewData.metaData!.toCommonsMetadata());
        expect(mapSentToClient['key'], 'public:$keyName');
      });

      test('plookup - in cache but key has expired, so refresh it', () async {
        AtData bobOriginalData = createRandomAtData(bob);
        bobOriginalData.metaData!.ttr = -1;
        bobOriginalData.metaData!.ttl = 5; // expire in 5 milliseconds
        bobOriginalData.data = "Old data";

        await cacheManager.put(cachedKeyName, bobOriginalData);
        expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);

        AtData bobNewData = AtData().fromJson(bobOriginalData.toJson());
        bobOriginalData.metaData!.ttr = -1;
        bobOriginalData.metaData!.ttl = 24 * 60 * 60 * 1000;
        bobNewData.data = "New data";
        String bobNewDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobNewData, key: 'public:$keyName')!;

        inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

        await Future.delayed(Duration(milliseconds: 6)); // Wait for 6 milliseconds so that the key has definitely expired

        when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
            .thenAnswer((Invocation invocation) async {
          socketOnDataFn("data:$bobNewDataAsJsonWithKey\n@".codeUnits);
        });

        // We expect the key to be refreshed
        verifyNever(() => mockOutboundConnection.write('lookup:all:$keyName\n'));
        await plookupVerbHandler.process('plookup:all:$keyName', inboundConnection);
        verify(() => mockOutboundConnection.write('lookup:all:$keyName\n')).called(1);

        Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
        expect(mapSentToClient['data'], bobNewData.data);
        expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
            bobNewData.metaData!.toCommonsMetadata());
        expect(mapSentToClient['key'], 'public:$keyName');
      });

      test('plookup - in cache but key has expired, and no longer exists', () async {
        AtData bobOriginalData = createRandomAtData(bob);
        bobOriginalData.metaData!.ttr = -1;
        bobOriginalData.metaData!.ttl = 5; // expire in 5 milliseconds
        bobOriginalData.data = "Old data";

        await cacheManager.put(cachedKeyName, bobOriginalData);
        expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);

        when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
            .thenAnswer((Invocation invocation) async {
          socketOnDataFn('error:{"errorCode":"AT0015","errorDescription":"$keyName does not exist"}\n$alice@'.codeUnits);
        });

        inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

        await Future.delayed(Duration(milliseconds: 6)); // Wait for 6 milliseconds so that the key has definitely expired

        // We expect a KeyNotFoundException
        await expectLater(plookupVerbHandler.process('plookup:all:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));
      });

      test('plookup - not in cache, and bypassCache requested, and key does not exist on remote', () async {
        when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
            .thenAnswer((Invocation invocation) async {
          socketOnDataFn('error:{"errorCode":"AT0015","errorDescription":"$keyName does not exist"}\n$alice@'.codeUnits);
        });

        inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

        await Future.delayed(Duration(milliseconds: 6)); // Wait for 6 milliseconds so that the key has definitely expired

        // We expect a KeyNotFoundException from the remote server
        verifyNever(() => mockOutboundConnection.write('lookup:all:$keyName\n'));
        await expectLater(plookupVerbHandler.process('plookup:bypassCache:true:all:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));
        verify(() => mockOutboundConnection.write('lookup:all:$keyName\n')).called(1);
      });
    });
  } catch (e, s) {
    print(s);
  }

  group('plookup (proxy lookup) syntax tests', () {
    SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
    OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
    AtCacheManager mockAtCacheManager = MockAtCacheManager();

    test('test proxy_lookup key-value', () {
      var verb = ProxyLookup();
      var command = 'plookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test proxy_lookup getVerb', () {
      var handler = ProxyLookupVerbHandler(mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var verb = handler.getVerb();
      expect(verb is ProxyLookup, true);
    });

    test('test proxy_lookup command accept test', () {
      var command = 'plookup:location@alice';
      var handler = ProxyLookupVerbHandler(mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test proxy_lookup regex', () {
      var verb = ProxyLookup();
      var command = 'plookup:location@🦄';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], '🦄');
    });

    test('test proxy_lookup with invalid atsign', () {
      var verb = ProxyLookup();
      var command = 'plookup:location@alice@@@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test proxy_lookup key- no atSign', () {
      var verb = ProxyLookup();
      var command = 'plookup:location';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test proxy_lookup key invalid keyword', () {
      var verb = ProxyLookup();
      var command = 'plokup:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
