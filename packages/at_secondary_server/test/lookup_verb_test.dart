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
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';
import 'package:mocktail/mocktail.dart';

import 'utils.dart' as utils;

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
  group('lookup behaviour tests', () {
    /// Test the actual behaviour of the lookup verb handler.
    /// (Syntax tests are covered in the next test group, 'lookup syntax tests')
    ///
    /// In each behaviour test we assert on
    /// * just the value (lookup:<atKey>)
    /// * just the metadata (lookup:meta:<atKey>)
    /// * value and metadata (lookup:all:<atKey>
    ///
    /// And each test
    /// * Asserts cache state before lookup (empty) and after lookup (there, or not)
    /// * And asserts cache fetch when looking up first time (nope), second time (yup)
    /// * And asserts cache always bypassed if bypassCache is set
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
    InboundConnection inboundConnection = DummyInboundConnection();
    registerFallbackValue(inboundConnection);
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
      bobPublicKeyAsJson = SecondaryUtil.prepareResponseData('all', bobPublicKeyAtData, keyToUseIfNotAlreadySetInAtData: 'public:publickey$bob')!;
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

    tearDownAll(() async {
      await AtAccessLogManagerImpl.getInstance().close();
    });

    test('@alice, via authenticated client to @alice server, lookup an @alice key that exists', () async {
      var keyName = 'some_key.some_namespace$bob';
      var cachedKeyName = 'cached:$alice:$keyName';

      expect(secondaryKeyStore.isKeyExists(keyName), false);
      expect(secondaryKeyStore.isKeyExists(cachedKeyName), false);

      AtData randomData = utils.createRandomAtData();
      randomData.metaData!.ttr = 10;
      String randomDataAsJson = SecondaryUtil.prepareResponseData('all', randomData, keyToUseIfNotAlreadySetInAtData: '$alice:$keyName')!;

      inboundConnection.getMetaData().isAuthenticated = true;

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$randomDataAsJson\n$alice@".codeUnits);
      });
      await lookupVerbHandler.process('lookup:$keyName', inboundConnection);

      expect(secondaryKeyStore.isKeyExists(cachedKeyName), true);
    });
    test('@alice, via authenticated client to @alice server, lookup an @alice key that does not exist', () {});
    test('@bob, via pol connection to @alice server, lookup an @alice key that exists', () {});
    test('@bob, via pol connection to @alice server, lookup an @alice key that does not exist', () {});
    test('unauthenticated lookup a key', () {});
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

