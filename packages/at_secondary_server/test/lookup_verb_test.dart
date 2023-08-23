import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// From the atProtocol specification:
/// The `lookup` verb should be used to fetch the value of the key shared by another @sign user. If there is a public and
/// user key with the same name then the result should be based on whether the user is trying to lookup is authenticated or
/// not. If the user is authenticated then the user key has to be returned, otherwise the public key has to be returned.
void main() {
  AtSignLogger.root_level = 'WARNING';
  group('lookup behaviour tests', () {
    /// Test the actual behaviour of the lookup verb handler.
    /// (Syntax tests are covered in the next test group, 'lookup syntax tests')
    ///
    /// We are using the concrete implementation of the SecondaryKeyStore in these tests as we
    /// don't need to mock its behaviour.

    late LookupVerbHandler lookupVerbHandler;

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test(
        '@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify cache and response',
        () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated

      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      Map mapSentToClient;

      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      // Response should have been cached
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      // Cached data should be identical to what was sent by @bob
      AtData cachedAtData = (await secondaryKeyStore.get(cachedKeyName))!;
      expect(cachedAtData.data, bobData.data);
      expect(cachedAtData.metaData!.toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(cachedAtData.key, cachedKeyName);

      // First lookup:all (when it's not in the cache) will have 'key' in the response of e.g.. @alice:foo.bar@bob
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$alice:$keyName');

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
    });

    test(
        '@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify publickey was cached',
        () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      // *************************************************************
      // In the course of doing the remote lookup, Bob's public key should have been fetched and cached
      //
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), true);
      // Let's remove our cache of Bob's public key because then we can verify that after the next lookup
      // retrieves from cache, there is no need to do a remote lookup and therefore Bob's public key won't have been fetched
      await cacheManager.delete(cachedBobsPublicKeyName);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);
      //
      // *************************************************************
    });

    test(
        '@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify fetched from cache',
        () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      Map mapSentToClient;

      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      // *************************************************************
      // In the course of doing the remote lookup, Bob's public key should have been fetched and cached
      //
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), true);
      // Let's remove our cache of Bob's public key because then we can verify that after the next lookup
      // retrieves from cache, there is no need to do a remote lookup and therefore Bob's public key won't have been fetched
      await cacheManager.delete(cachedBobsPublicKeyName);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);
      //
      // *************************************************************

      // Now let's do the lookup again - this time it should be fetched from cache
      // This time the 'key' in the response should have the 'cached:' prefix e.g. cached:@alice:foo.bar@bob
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], 'cached:$alice:$keyName');

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      // We didn't do a remote lookup, so bob's public key should not have been cached
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);
    });

    test(
        '@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify bypassCache',
        () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      Map mapSentToClient;

      // Do a first lookup, to populate the cache
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      // Now let's do the lookup again, but setting the bypassCache flag
      // This time the 'key' in the response should NOT have the 'cached:' prefix
      verify(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .callCount; // getting the call count will clear the call count
      verifyNever(() => mockOutboundConnection.write('lookup:all:$keyName\n'));
      await lookupVerbHandler.process(
          'lookup:bypassCache:true:all:$keyName', inboundConnection);

      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$alice:$keyName');

      verify(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .called(1);
    });

    test(
        '@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify lookup flavours',
        () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      Map mapSentToClient;

      // Now let's test the other flavours of lookup (just data, just metadata)
      // First - just the data
      // (a) when doing remote lookup
      await cacheManager.delete(cachedKeyName);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      await lookupVerbHandler.process('lookup:$keyName', inboundConnection);
      expect(
          inboundConnection.lastWrittenData!, 'data:${bobData.data}\n$alice@');
      // (b) and when it's been cached
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      await lookupVerbHandler.process('lookup:$keyName', inboundConnection);
      expect(
          inboundConnection.lastWrittenData!, 'data:${bobData.data}\n$alice@');

      // Second - just the metaData
      // (a) when doing remote lookup
      await cacheManager.delete(cachedKeyName);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      await lookupVerbHandler.process(
          'lookup:meta:$keyName', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(AtMetaData.fromJson(mapSentToClient).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      // (b) and when it's been cached
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      await lookupVerbHandler.process(
          'lookup:meta:$keyName', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(AtMetaData.fromJson(mapSentToClient).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
    });

    test(
        '@alice, to @alice server, lookup a key that @bob has shared with ttr null or zero',
        () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // if @alice caches, the key would be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);

      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = null;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      inboundConnection.getMetaData().isAuthenticated =
          true; // owner connection, authenticated

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      // Response should not have been cached
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(keyName), false);

      Map mapSentToClient;
      // When returned from remote lookup, the 'key' in the response should be e.g.. @alice:foo.bar@bob
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$alice:$keyName');
    });

    test('@alice, to @alice server, lookup a key that does not exist',
        () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';

      inboundConnection.getMetaData().isAuthenticated =
          true; // owner connection, authenticated

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn(
            'error:{"errorCode":"AT0015","errorDescription":"$keyName does not exist"}\n$alice@'
                .codeUnits);
      });
      await expectLater(
          lookupVerbHandler.process('lookup:all:$keyName', inboundConnection),
          throwsA(isA<KeyNotFoundException>()));
    });

    test(
        '@bob, via pol connection to @alice server, lookup a key that @alice has shared',
        () async {
      // some key sharedBy @alice
      var keyName = 'some_key.some_namespace$alice';

      AtData aliceData = createRandomAtData(alice);
      aliceData.metaData!.ttr = null;
      aliceData.metaData!.ttb = null;
      aliceData.metaData!.ttl = null;

      await secondaryKeyStore.put('$bob:$keyName', aliceData);
      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists('$bob:$keyName'), true);

      inboundConnection.getMetaData().isPolAuthenticated =
          true; // connection from @bob atServer to @alice atServer, polAuthenticated
      inboundConnection.metadata.self = false;
      inboundConnection.metadata.from = true;
      inboundConnection.metadata.fromAtSign = bob;

      // The sharedWith atSign is always prepended, even if it's been supplied. So, when it is
      // supplied, the search will be for e.g. @bob:@bob:foo.bar@alice
      // So let's just assert that this will throw a KeyNotFoundException
      await expectLater(
          lookupVerbHandler.process(
              'lookup:all:$bob:$keyName', inboundConnection),
          throwsA(isA<KeyNotFoundException>()));

      // But looking it up is fine when we don't provide sharedWith in the lookup command
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      Map mapSentToClient;
      // When returned from remote lookup, the 'key' in the response should be e.g.. @alice:foo.bar@bob
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], aliceData.data);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          aliceData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$bob:$keyName');
    });

    test(
        '@bob, via pol connection to @alice server, lookup a key that does not exist',
        () async {
      // some key sharedBy @alice
      var keyName = 'some_key.some_namespace$alice';

      inboundConnection.metadata.isPolAuthenticated =
          true; // connection from @bob atServer to @alice atServer, polAuthenticated
      inboundConnection.metadata.self = false;
      inboundConnection.metadata.from = true;
      inboundConnection.metadata.fromAtSign = bob;

      await expectLater(
          lookupVerbHandler.process('lookup:all:$keyName', inboundConnection),
          throwsA(isA<KeyNotFoundException>()));
    });

    test(
        'unauthenticated client to @alice server lookup a key owned by @alice that exists and is public',
        () async {
      // some key sharedBy @alice
      var keyName = 'firstname.wavi$alice';

      AtData aliceData = createRandomAtData(alice);
      aliceData.data = 'Alice';
      aliceData.metaData!.ttr = 0;
      aliceData.metaData!.ttb = 0;
      aliceData.metaData!.ttl = 0;

      await secondaryKeyStore.put('public:$keyName', aliceData);
      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists('public:$keyName'), true);

      expect(inboundConnection.metadata.isAuthenticated, false);
      expect(inboundConnection.metadata.isPolAuthenticated, false);
      expect(inboundConnection.metadata.fromAtSign, null);

      // public: is always prepended, even if it's been supplied. So, when it is
      // supplied, the search will be for e.g. public:public:foo.bar@alice
      // So let's just assert that this will throw a KeyNotFoundException
      await expectLater(
          lookupVerbHandler.process(
              'lookup:all:public:$keyName', inboundConnection),
          throwsA(isA<KeyNotFoundException>()));

      // But looking it up is fine when we don't provide sharedWith in the lookup command
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      Map mapSentToClient;
      // When returned from remote lookup, the 'key' in the response should be e.g.. @alice:foo.bar@bob
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], aliceData.data);
      expect(mapSentToClient['data'], 'Alice');
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          aliceData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], 'public:$keyName');
    });

    test(
        'unauthenticated client to @alice server lookup a key owned by @alice that exists and is not public',
        () async {
      // some key owned by @alice
      var keyName = 'some_key.some_namespace$alice';

      AtData aliceData = createRandomAtData(alice);
      aliceData.metaData!.ttr = 0;
      aliceData.metaData!.ttb = 0;
      aliceData.metaData!.ttl = 0;

      await secondaryKeyStore.put(keyName, aliceData);
      expect(secondaryKeyStore.isKeyExists(keyName), true);

      expect(inboundConnection.metadata.isAuthenticated, false);
      expect(inboundConnection.metadata.isPolAuthenticated, false);
      expect(inboundConnection.metadata.fromAtSign, null);

      await expectLater(
          lookupVerbHandler.process('lookup:all:$keyName', inboundConnection),
          throwsA(isA<KeyNotFoundException>()));
    });
  });

  group('lookup syntax tests', () {
    SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
    OutboundClientManager mockOutboundClientManager =
        MockOutboundClientManager();
    AtCacheManager mockAtCacheManager = MockAtCacheManager();

    test('test lookup key-value', () {
      var verb = Lookup();
      var command = 'lookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test lookup getVerb', () {
      var handler = LookupVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var verb = handler.getVerb();
      expect(verb is Lookup, true);
    });

    test('test lookup command accept test', () {
      var command = 'lookup:location@alice';
      var handler = LookupVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test lookup key- no atSign', () {
      var verb = Lookup();
      var command = 'lookup:location';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup key- invalid atsign', () {
      var verb = Lookup();
      var command = 'lookup:location@alice@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup with emoji', () {
      var verb = Lookup();
      var command = 'lookup:email@🐼';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], '🐼');
    });

    test('test lookup with emoji-invalid syntax', () {
      var verb = Lookup();
      var command = 'lookup:email🐼';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup key- invalid keyword', () {
      var verb = Lookup();
      var command = 'lokup:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of tests related to APKAM enrollment', () {
    setUpAll(() async {
      await verbTestsSetUpAll();
    });
    setUp(() async {
      await verbTestsSetUp();
    });

    test('when enrollment namespace *:r, @alice lookup a key shared by bob',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var enrollmentKey = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          enrollmentKey, AtData()..data = jsonEncode(enrollJson));

      // Wavi key
      String waviKey = 'some_key.wavi$bob';
      AtData bobWaviData = createRandomAtData(bob);
      print('Wavi key: ${bobWaviData.data}');
      bobWaviData.metaData!.ttr = 100;
      bobWaviData.metaData!.ttb = null;
      bobWaviData.metaData!.ttl = null;
      String bobWaviDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobWaviData,
          key: '$alice:$waviKey')!;

      // Buzz key
      String buzzKey = 'some_key.buzz$bob';
      AtData bobBuzzData = createRandomAtData(bob);
      print('Buzz key: ${bobBuzzData.data}');
      bobBuzzData.metaData!.ttr = 100;
      bobBuzzData.metaData!.ttb = null;
      bobBuzzData.metaData!.ttl = null;
      String bobBuzzDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobBuzzData,
          key: '$alice:$buzzKey')!;

      when(() => mockOutboundConnection.write('lookup:all:$waviKey\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobWaviDataAsJsonWithKey\n$alice@".codeUnits);
      });

      when(() => mockOutboundConnection.write('lookup:all:$buzzKey\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobBuzzDataAsJsonWithKey\n$alice@".codeUnits);
      });

      Map mapSentToClient;

      LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      await lookupVerbHandler.process('lookup:all:$waviKey', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobWaviData.data);

      lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      await lookupVerbHandler.process('lookup:all:$buzzKey', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobBuzzData.data);
    });

    test(
        'when enrollment namespace is authorized, @alice lookup a key shared by bob - cached key does not exist',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      // some key sharedBy @bob
      keyName = 'some_key.wavi$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      Map mapSentToClient;

      LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      // Response should have been cached
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      // Cached data should be identical to what was sent by @bob
      AtData cachedAtData = (await secondaryKeyStore.get(cachedKeyName))!;
      expect(cachedAtData.data, bobData.data);
      expect(cachedAtData.metaData!.toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(cachedAtData.key, cachedKeyName);

      // First lookup:all (when it's not in the cache) will have 'key' in the response of e.g.. @alice:foo.bar@bob
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$alice:$keyName');

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
    });

    test(
        'when enrollment namespace is authorized, @alice lookup a key shared by bob - cached key exists on alice secondary',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      // some key sharedBy @bob
      keyName = 'some_key.wavi$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';
      AtData bobData = AtData()
        ..data = 'cached_key_value'
        ..metaData = (AtMetaData()..ttr = 10000);
      // Insert a cached key
      await secondaryKeyStore.put(cachedKeyName, bobData);

      LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      var mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['key'], 'cached:$alice:$keyName');
      expect(mapSentToClient['data'], bobData.data);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
    });

    test('when enrollment namespace is authorized, @alice lookup a self key',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      // Self key stored by alice
      keyName = 'some_key.wavi$alice';
      AtData aliceData = createRandomAtData(alice);
      // Insert a key
      await secondaryKeyStore.put('$alice:$keyName', aliceData);

      LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);
      var mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(aliceData.data, mapSentToClient['data']);
    });

    test(
        'A test to verify enrollment namespace not authorized throws exception when @alice lookup a self key',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      // Self key stored by alice
      keyName = 'some_key.buzz$alice';
      AtData aliceData = createRandomAtData(alice);
      // Insert a key
      await secondaryKeyStore.put('$alice:$keyName', aliceData);

      LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      expect(
          () async => await lookupVerbHandler.process(
              'lookup:all:$keyName', inboundConnection),
          throwsA(predicate((e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Enrollment Id: $enrollmentId is not authorized for lookup operation on the key: @alice:some_key.buzz@alice')));
    });

    test(
        'A test to verify enrollment namespace is not authorized, @alice lookup a key shared by bob',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      // some key sharedBy @bob
      keyName = 'some_key.buzz$bob';

      LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      expect(
          () async => await lookupVerbHandler.process(
              'lookup:all:$keyName', inboundConnection),
          throwsA(predicate((e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Enrollment Id: $enrollmentId is not authorized for lookup operation on the key: @alice:some_key.buzz@bob')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A of tests to verify lookup a key when enrollment is pending/revoke/denied state throws exception',
      () {
    setUpAll(() async {
      await verbTestsSetUpAll();
    });
    setUp(() async {
      await verbTestsSetUp();
    });
    Response response = Response();
    String enrollmentId;
    List operationList = ['pending', 'revoked', 'denied'];

    for (var operation in operationList) {
      test(
          'A test to verify when enrollment is $operation throws exception on a key lookup',
          () async {
        inboundConnection.metadata.isAuthenticated = true;
        enrollmentId = Uuid().v4();
        inboundConnection.metadata.enrollmentId = enrollmentId;
        final enrollJson = {
          'sessionId': '123',
          'appName': 'wavi',
          'deviceName': 'pixel',
          'namespaces': {'wavi': 'rw'},
          'apkamPublicKey': 'testPublicKeyValue',
          'requestType': 'newEnrollment',
          'approval': {'state': operation}
        };
        await secondaryKeyStore.put(
            '$enrollmentId.new.enrollments.__manage@alice',
            AtData()..data = jsonEncode(enrollJson));
        inboundConnection.metadata.enrollmentId = enrollmentId;
        String llookupCommand = 'lookup:dummykey.wavi$bob';
        HashMap<String, String?> lookupVerbParams =
            getVerbParam(VerbSyntax.lookup, llookupCommand);
        LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
            secondaryKeyStore, mockOutboundClientManager, cacheManager);
        expect(
            () async => await lookupVerbHandler.processVerb(
                response, lookupVerbParams, inboundConnection),
            throwsA(predicate((dynamic e) =>
                e is UnAuthorizedException &&
                e.message ==
                    'Enrollment Id: $enrollmentId is not authorized for lookup operation on the key: @alice:dummykey.wavi@bob')));
      });
    }
  });

  group('A group of tests to verify lookup of reserved keys', () {
    setUpAll(() async {
      await verbTestsSetUpAll();
    });
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'A test to verify shared key is fetched when connection authenticated via APKAM',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var enrollmentKey = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          enrollmentKey, AtData()..data = jsonEncode(enrollJson));

      String sharedKey = 'shared_key$bob';
      AtData bobWaviData = createRandomAtData(bob);
      bobWaviData.metaData!.ttr = 100;
      bobWaviData.metaData!.ttb = null;
      bobWaviData.metaData!.ttl = null;
      String bobWaviDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobWaviData,
          key: '$alice:$sharedKey')!;

      when(() => mockOutboundConnection.write('lookup:all:$sharedKey\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobWaviDataAsJsonWithKey\n$alice@".codeUnits);
      });

      Map mapSentToClient;

      LookupVerbHandler lookupVerbHandler = LookupVerbHandler(
          secondaryKeyStore, mockOutboundClientManager, cacheManager);
      await lookupVerbHandler.process(
          'lookup:all:$sharedKey', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobWaviData.data);
    });
    tearDown(() async => await verbTestsTearDown());
  });
}
