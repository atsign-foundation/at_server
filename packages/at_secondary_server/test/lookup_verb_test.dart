import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';
import 'package:mocktail/mocktail.dart';

import 'utils.dart' as test_utils;

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}
class MockOutboundClientManager extends Mock implements OutboundClientManager {}
class MockAtCacheManager extends Mock implements AtCacheManager {}
class MockSecondaryAddressFinder extends Mock implements at_lookup.SecondaryAddressFinder {}
class MockOutboundConnectionFactory extends Mock implements OutboundConnectionFactory {}
class MockOutboundConnection extends Mock implements OutboundConnection {}
class MockSecureSocket extends Mock implements SecureSocket {}
class MockStreamSubscription<T> extends Mock implements StreamSubscription<T> {}

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

    String alice = '@alice';
    String bob = '@bob';
    var bobHost = "domain.testing.bob.bob.bob";
    var bobPort = 12345;
    var bobServerSigningKeypair = RSAKeypair.fromRandom();
    var bobPublicKeypair = RSAKeypair.fromRandom();
    late AtData bobPublicKeyAtData;
    late String bobPublicKeyAsJson;

    late SecondaryKeyStore<String, AtData?, AtMetaData?> secondaryKeyStore;
    late LookupVerbHandler lookupVerbHandler;
    late AtCacheManager cacheManager;
    late MockOutboundClientManager mockOutboundClientManager;
    late OutboundClient outboundClientWithHandshake;
    late OutboundClient outboundClientWithoutHandshake;
    late MockOutboundConnectionFactory mockOutboundConnectionFactory;
    late MockOutboundConnection mockOutboundConnection;
    late MockSecondaryAddressFinder mockSecondaryAddressFinder;
    late MockSecureSocket mockSecureSocket;
    late DummyInboundConnection inboundConnection;
    late Function(dynamic data) socketOnDataFn;
    // ignore: unused_local_variable
    late Function() socketOnDoneFn;
    // ignore: unused_local_variable
    late Function(Exception e) socketOnErrorFn;

    String storageDir = '${Directory.current.path}/unit_test_storage';
    SecondaryPersistenceStore? secondaryPersistenceStore;
    AtCommitLog? atCommitLog;

    setUpAll(() async {
      await AtAccessLogManagerImpl.getInstance()
          .getAccessLog(alice, accessLogPath: storageDir);
    });

    setUp(() async {
      // Initialize secondary persistent store
      secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(alice);
      // Initialize commit log
      atCommitLog = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(alice, commitLogPath: storageDir, enableCommitId: true);
      secondaryPersistenceStore!.getSecondaryKeyStore()?.commitLog = atCommitLog;
      // Init the hive instances
      await secondaryPersistenceStore!
          .getHivePersistenceManager()!
          .init(storageDir);

      secondaryKeyStore = secondaryPersistenceStore!.getSecondaryKeyStore()!;

      mockSecondaryAddressFinder = MockSecondaryAddressFinder();
      when(() => mockSecondaryAddressFinder.findSecondary(bob))
          .thenAnswer((_) async {
            return at_lookup.SecondaryAddress(bobHost, bobPort);
      });

      mockOutboundConnection = MockOutboundConnection();
      mockOutboundConnectionFactory = MockOutboundConnectionFactory();
      when(() => mockOutboundConnectionFactory.createOutboundConnection(bobHost, bobPort, bob))
          .thenAnswer((invocation) async {
            return mockOutboundConnection;
      });

      inboundConnection = DummyInboundConnection();
      registerFallbackValue(inboundConnection);

      outboundClientWithHandshake = OutboundClient(inboundConnection, bob,
          secondaryAddressFinder: mockSecondaryAddressFinder, outboundConnectionFactory: mockOutboundConnectionFactory)
        ..notifyTimeoutMillis = 100
        ..lookupTimeoutMillis = 100
        ..toHost = bobHost
        ..toPort = bobPort.toString()
        ..productionMode = false;
      outboundClientWithoutHandshake = OutboundClient(inboundConnection, bob,
          secondaryAddressFinder: mockSecondaryAddressFinder, outboundConnectionFactory: mockOutboundConnectionFactory)
        ..notifyTimeoutMillis = 100
        ..lookupTimeoutMillis = 100
        ..toHost = bobHost
        ..toPort = bobPort.toString()
        ..productionMode = false;

      mockOutboundClientManager = MockOutboundClientManager();
      when(() => mockOutboundClientManager.getClient(bob, any(), isHandShake: true))
          .thenAnswer((_) {
            return outboundClientWithHandshake;
      });
      when(() => mockOutboundClientManager.getClient(bob, any(), isHandShake: false))
          .thenAnswer((_) {
            return outboundClientWithoutHandshake;
      });

      AtConnectionMetaData outboundConnectionMetadata = OutboundConnectionMetadata();
      outboundConnectionMetadata.sessionID = 'mock-session-id';
      when(() => mockOutboundConnection.getMetaData())
          .thenReturn(outboundConnectionMetadata);
      when(() => mockOutboundConnection.metaData)
          .thenReturn(outboundConnectionMetadata);

      mockSecureSocket = MockSecureSocket();
      when(() => mockOutboundConnection.getSocket())
          .thenAnswer((_) => mockSecureSocket);
      when(() => mockOutboundConnection.close()).thenAnswer((_) async => {});

      when(() => mockSecureSocket.listen(any(),
          onError: any(named: "onError"),
          onDone: any(named: "onDone"))).thenAnswer((Invocation invocation) {
        socketOnDataFn = invocation.positionalArguments[0];
        socketOnDoneFn = invocation.namedArguments[#onDone];
        socketOnErrorFn = invocation.namedArguments[#onError];

        return MockStreamSubscription();
      });

      cacheManager = AtCacheManager(alice, secondaryKeyStore, mockOutboundClientManager);

      AtSecondaryServerImpl.getInstance().cacheManager = cacheManager;
      AtSecondaryServerImpl.getInstance().secondaryKeyStore = secondaryKeyStore;
      AtSecondaryServerImpl.getInstance().outboundClientManager = mockOutboundClientManager;
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      AtSecondaryServerImpl.getInstance().signingKey = bobServerSigningKeypair.privateKey.toString();

      lookupVerbHandler = LookupVerbHandler(secondaryKeyStore, mockOutboundClientManager, cacheManager);

      bobPublicKeyAtData = AtData();
      DateTime now = DateTime.now().toUtc();
      bobPublicKeyAtData.data = bobPublicKeypair.publicKey.toString();
      bobPublicKeyAtData.metaData = AtMetaData()..ttr=-1..createdAt=now..updatedAt=now;
      bobPublicKeyAsJson = SecondaryUtil.prepareResponseData('all', bobPublicKeyAtData, key: 'public:publickey$bob')!;
      var roundTrip = AtData();
      roundTrip.fromJson(jsonDecode(bobPublicKeyAsJson));

      when(() => mockOutboundConnection.write(any()))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn(
            'error:AT0001-Mock exception : '
                'No mock response defined for request '
                '[${invocation.positionalArguments[0]}]\n$alice@'
                .codeUnits);
      });
      when(() => mockOutboundConnection.write('from:$alice\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:proof:mock-session-id$bob:server-challenge-text\n@".codeUnits); // actual challenge is different, of course, but not important for unit tests
      });
      when(() => mockOutboundConnection.write('pol\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("$alice@".codeUnits);
      });
      when(() => mockOutboundConnection.write('lookup:all:publickey@bob\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobPublicKeyAsJson\n$alice@".codeUnits);
      });
    });

    tearDown(() async {
      await SecondaryPersistenceStoreFactory.getInstance().close();
      await AtCommitLogManagerImpl.getInstance().close();
      var isExists = await Directory(storageDir).exists();
      if (isExists) {
        Directory(storageDir).deleteSync(recursive: true);
      }
    });

    test('@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify cache and response', () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';
      var cachedBobsPublicKeyName = 'cached:public:publickey@bob';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = test_utils.createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

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
      expect(cachedAtData.metaData!.toCommonsMetadata(), bobData.metaData!.toCommonsMetadata());
      expect(cachedAtData.key, cachedKeyName);

      // First lookup:all (when it's not in the cache) will have 'key' in the response of e.g.. @alice:foo.bar@bob
      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$alice:$keyName');

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
    });

    test('@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify publickey was cached', () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';
      var cachedBobsPublicKeyName = 'cached:public:publickey@bob';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = test_utils.createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

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

    });

    test('@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify fetched from cache', () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';
      var cachedBobsPublicKeyName = 'cached:public:publickey@bob';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = test_utils.createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

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

      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], 'cached:$alice:$keyName');

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      // We didn't do a remote lookup, so bob's public key should not have been cached
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);
    });

    test('@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify bypassCache', () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';
      var cachedBobsPublicKeyName = 'cached:public:publickey@bob';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = test_utils.createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

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
      await lookupVerbHandler.process('lookup:bypassCache:true:all:$keyName', inboundConnection);

      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$alice:$keyName');

      verify(() => mockOutboundConnection.write('lookup:all:$keyName\n')).called(1);
    });

    test('@alice, to @alice server, lookup a key that @bob has shared with ttr 10 - verify lookup flavours', () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // when @alice caches, the key will be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';
      var cachedBobsPublicKeyName = 'cached:public:publickey@bob';

      await secondaryKeyStore.remove(keyName);
      await secondaryKeyStore.remove(cachedKeyName);
      await secondaryKeyStore.remove(cachedBobsPublicKeyName);

      AtData bobData = test_utils.createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$keyName')!;

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedBobsPublicKeyName), false);

      inboundConnection.metadata.isAuthenticated = true; // owner connection, authenticated

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
      expect(inboundConnection.lastWrittenData!, 'data:${bobData.data}\n$alice@');
      // (b) and when it's been cached
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      await lookupVerbHandler.process('lookup:$keyName', inboundConnection);
      expect(inboundConnection.lastWrittenData!, 'data:${bobData.data}\n$alice@');

      // Second - just the metaData
      // (a) when doing remote lookup
      await cacheManager.delete(cachedKeyName);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);
      await lookupVerbHandler.process('lookup:meta:$keyName', inboundConnection);
      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(AtMetaData.fromJson(mapSentToClient).toCommonsMetadata(), bobData.metaData!.toCommonsMetadata());
      // (b) and when it's been cached
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
      await lookupVerbHandler.process('lookup:meta:$keyName', inboundConnection);
      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(AtMetaData.fromJson(mapSentToClient).toCommonsMetadata(), bobData.metaData!.toCommonsMetadata());
    });

    test('@alice, to @alice server, lookup a key that @bob has shared with ttr null or zero', () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';
      // if @alice caches, the key would be prefixed with 'cached:@alice:'
      var cachedKeyName = 'cached:$alice:$keyName';

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);

      AtData bobData = test_utils.createRandomAtData(bob);
      bobData.metaData!.ttr = null;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$keyName')!;

      inboundConnection.getMetaData().isAuthenticated = true; // owner connection, authenticated

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
      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], bobData.data);
      expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(), bobData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$alice:$keyName');
    });

    test('@alice, to @alice server, lookup a key that does not exist', () async {
      // some key sharedBy @bob
      var keyName = 'some_key.some_namespace$bob';

      inboundConnection.getMetaData().isAuthenticated = true; // owner connection, authenticated

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn('error:{"errorCode":"AT0015","errorDescription":"$keyName does not exist"}\n$alice@'.codeUnits);
      });
      await expectLater(lookupVerbHandler.process('lookup:all:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));
    });

    test('@bob, via pol connection to @alice server, lookup a key that @alice has shared', () async {
      // some key sharedBy @alice
      var keyName = 'some_key.some_namespace$alice';

      AtData aliceData = test_utils.createRandomAtData(alice);
      aliceData.metaData!.ttr = null;
      aliceData.metaData!.ttb = null;
      aliceData.metaData!.ttl = null;

      await secondaryKeyStore.put('$bob:$keyName', aliceData);
      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists('$bob:$keyName'), true);

      inboundConnection.getMetaData().isPolAuthenticated = true; // connection from @bob atServer to @alice atServer, polAuthenticated
      inboundConnection.metadata.self = false;
      inboundConnection.metadata.from = true;
      inboundConnection.metadata.fromAtSign = bob;

      // The sharedWith atSign is always prepended, even if it's been supplied. So, when it is
      // supplied, the search will be for e.g. @bob:@bob:foo.bar@alice
      // So let's just assert that this will throw a KeyNotFoundException
      await expectLater(lookupVerbHandler.process('lookup:all:$bob:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));

      // But looking it up is fine when we don't provide sharedWith in the lookup command
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      Map mapSentToClient;
      // When returned from remote lookup, the 'key' in the response should be e.g.. @alice:foo.bar@bob
      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], aliceData.data);
      expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(), aliceData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], '$bob:$keyName');
    });

    test('@alice, via pol connection to @bob server, lookup a key that does not exist', () async {
      // some key sharedBy @alice
      var keyName = 'some_key.some_namespace$alice';

      inboundConnection.metadata.isPolAuthenticated = true; // connection from @bob atServer to @alice atServer, polAuthenticated
      inboundConnection.metadata.self = false;
      inboundConnection.metadata.from = true;
      inboundConnection.metadata.fromAtSign = bob;

      await expectLater(lookupVerbHandler.process('lookup:all:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));
    });

    test('unauthenticated client to @alice server lookup a key owned by @alice that exists and is public', () async {
      // some key sharedBy @alice
      var keyName = 'firstname.wavi$alice';

      AtData aliceData = test_utils.createRandomAtData(alice);
      aliceData.data = 'Alice';
      aliceData.metaData!.ttr = 0;
      aliceData.metaData!.ttb = 0;
      aliceData.metaData!.ttl = 0;

      await secondaryKeyStore.put('public:$keyName', aliceData);
      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists('public:$keyName'), true);

      expect (inboundConnection.metadata.isAuthenticated, false);
      expect (inboundConnection.metadata.isPolAuthenticated, false);
      expect (inboundConnection.metadata.fromAtSign, null);

      // public: is always prepended, even if it's been supplied. So, when it is
      // supplied, the search will be for e.g. public:public:foo.bar@alice
      // So let's just assert that this will throw a KeyNotFoundException
      await expectLater(lookupVerbHandler.process('lookup:all:public:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));

      // But looking it up is fine when we don't provide sharedWith in the lookup command
      await lookupVerbHandler.process('lookup:all:$keyName', inboundConnection);

      Map mapSentToClient;
      // When returned from remote lookup, the 'key' in the response should be e.g.. @alice:foo.bar@bob
      mapSentToClient = test_utils.decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data'], aliceData.data);
      expect(mapSentToClient['data'], 'Alice');
      expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(), aliceData.metaData!.toCommonsMetadata());
      expect(mapSentToClient['key'], 'public:$keyName');
    });

    test('unauthenticated client to @alice server lookup a key owned by @alice that exists and is not public', () async {
      // some key owned by @alice
      var keyName = 'some_key.some_namespace$alice';

      AtData aliceData = test_utils.createRandomAtData(alice);
      aliceData.metaData!.ttr = 0;
      aliceData.metaData!.ttb = 0;
      aliceData.metaData!.ttl = 0;

      await secondaryKeyStore.put(keyName, aliceData);
      expect(secondaryKeyStore.isKeyExists(keyName), true);

      expect (inboundConnection.metadata.isAuthenticated, false);
      expect (inboundConnection.metadata.isPolAuthenticated, false);
      expect (inboundConnection.metadata.fromAtSign, null);

      await expectLater(lookupVerbHandler.process('lookup:all:$keyName', inboundConnection), throwsA(isA<KeyNotFoundException>()));
    });
  });

  group('lookup syntax tests', () {
    SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
    OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
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
      var handler = LookupVerbHandler(mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var verb = handler.getVerb();
      expect(verb is Lookup, true);
    });

    test('test lookup command accept test', () {
      var command = 'lookup:location@alice';
      var handler = LookupVerbHandler(mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
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
}

