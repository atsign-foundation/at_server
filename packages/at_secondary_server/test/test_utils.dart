import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:crypton/crypton.dart';
import 'package:mocktail/mocktail.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

class MockOutboundClientManager extends Mock implements OutboundClientManager {}

class MockNotificationManager extends Mock implements NotificationManager {}

class MockStatsNotificationService extends Mock
    implements StatsNotificationService {}

class MockAtCacheManager extends Mock implements AtCacheManager {}

class MockSecondaryAddressFinder extends Mock
    implements at_lookup.SecondaryAddressFinder {}

class MockOutboundConnectionFactory extends Mock
    implements OutboundConnectionFactory {}

class MockOutboundConnection extends Mock implements OutboundConnection {}

class MockSecureSocket extends Mock implements SecureSocket {}

class MockStreamSubscription<T> extends Mock implements StreamSubscription<T> {}

String alice = '@alice';
String aliceEmoji = '@alice🛠';
String bob = '@bob';
var bobHost = "domain.testing.bob.bob.bob";
var bobPort = 12345;
var bobServerSigningKeypair = RSAKeypair.fromRandom();

var bobOriginalPublicKeypair = RSAKeypair.fromRandom();
late AtData bobOriginalPublicKeyAtData;
late String bobOriginalPublicKeyAsJson;

var cachedBobsPublicKeyName = 'cached:public:publickey@bob';

late SecondaryKeyStore<String, AtData?, AtMetaData?> secondaryKeyStore;
late AtCacheManager cacheManager;
late MockOutboundClientManager mockOutboundClientManager;
late OutboundClient outboundClientWithHandshake;
late OutboundClient outboundClientWithoutHandshake;
late MockOutboundConnectionFactory mockOutboundConnectionFactory;
late MockOutboundConnection mockOutboundConnection;
late MockSecondaryAddressFinder mockSecondaryAddressFinder;
late MockSecureSocket mockSecureSocket;
late DummyInboundConnection inboundConnection;
late MockNotificationManager notificationManager;
late MockStatsNotificationService statsNotificationService;
late Function(dynamic data) socketOnDataFn;
// ignore: unused_local_variable
late Function() socketOnDoneFn;
// ignore: unused_local_variable
late Function(Exception e) socketOnErrorFn;

String storageDir = '${Directory.current.path}/unit_test_storage';
SecondaryPersistenceStore? secondaryPersistenceStore;
AtCommitLog? atCommitLog;

verbTestsSetUpAll() async {
  await AtAccessLogManagerImpl.getInstance()
      .getAccessLog(alice, accessLogPath: storageDir);
}

verbTestsSetUp() async {
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
  when(() => mockOutboundConnectionFactory.createOutboundConnection(
      bobHost, bobPort, bob)).thenAnswer((invocation) async {
    return mockOutboundConnection;
  });

  inboundConnection = DummyInboundConnection();
  registerFallbackValue(inboundConnection);

  outboundClientWithHandshake = OutboundClient(inboundConnection, bob,
      secondaryAddressFinder: mockSecondaryAddressFinder,
      outboundConnectionFactory: mockOutboundConnectionFactory)
    ..notifyTimeoutMillis = 100
    ..lookupTimeoutMillis = 100
    ..toHost = bobHost
    ..toPort = bobPort.toString()
    ..productionMode = false;
  outboundClientWithoutHandshake = OutboundClient(inboundConnection, bob,
      secondaryAddressFinder: mockSecondaryAddressFinder,
      outboundConnectionFactory: mockOutboundConnectionFactory)
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
  when(() =>
          mockOutboundClientManager.getClient(bob, any(), isHandShake: false))
      .thenAnswer((_) {
    return outboundClientWithoutHandshake;
  });

  AtConnectionMetaData outboundConnectionMetadata =
      OutboundConnectionMetadata();
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

  cacheManager =
      AtCacheManager(alice, secondaryKeyStore, mockOutboundClientManager);

  AtSecondaryServerImpl.getInstance().cacheManager = cacheManager;
  AtSecondaryServerImpl.getInstance().secondaryKeyStore = secondaryKeyStore;
  AtSecondaryServerImpl.getInstance().outboundClientManager =
      mockOutboundClientManager;
  AtSecondaryServerImpl.getInstance().currentAtSign = alice;
  AtSecondaryServerImpl.getInstance().signingKey =
      bobServerSigningKeypair.privateKey.toString();

  DateTime now = DateTime.now().toUtcMillisecondsPrecision();
  bobOriginalPublicKeyAtData = AtData();
  bobOriginalPublicKeyAtData.data =
      bobOriginalPublicKeypair.publicKey.toString();
  bobOriginalPublicKeyAtData.metaData = AtMetaData()
    ..ttr = -1
    ..createdAt = now
    ..updatedAt = now;
  bobOriginalPublicKeyAsJson = SecondaryUtil.prepareResponseData(
      'all', bobOriginalPublicKeyAtData,
      key: 'public:publickey$bob')!;
  bobOriginalPublicKeyAtData =
      AtData().fromJson(jsonDecode(bobOriginalPublicKeyAsJson));

  when(() => mockOutboundConnection.write(any()))
      .thenAnswer((Invocation invocation) async {
    socketOnDataFn('error:AT0001-Mock exception : '
            'No mock response defined for request '
            '[${invocation.positionalArguments[0]}]\n$alice@'
        .codeUnits);
  });
  when(() => mockOutboundConnection.write('from:$alice\n'))
      .thenAnswer((Invocation invocation) async {
    socketOnDataFn("data:proof:mock-session-id$bob:server-challenge-text\n@"
        .codeUnits); // actual challenge is different, of course, but not important for unit tests
  });
  when(() => mockOutboundConnection.write('pol\n'))
      .thenAnswer((Invocation invocation) async {
    socketOnDataFn("$alice@".codeUnits);
  });
  when(() => mockOutboundConnection.write('lookup:all:publickey@bob\n'))
      .thenAnswer((Invocation invocation) async {
    socketOnDataFn("data:$bobOriginalPublicKeyAsJson\n$alice@".codeUnits);
  });

  notificationManager = MockNotificationManager();
  registerFallbackValue(AtNotificationBuilder().build());
  when(() => notificationManager.notify(any()))
      .thenAnswer((invocation) async => 'some-notification-id');

  statsNotificationService = MockStatsNotificationService();
  when(() => statsNotificationService.writeStatsToMonitor())
      .thenAnswer((invocation) {});
}

Future<void> verbTestsTearDown() async {
  await SecondaryPersistenceStoreFactory.getInstance().close();
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory(storageDir).exists();
  if (isExists) {
    Directory(storageDir).deleteSync(recursive: true);
  }
}

final Random testUtilsRandom = Random();

Map decodeResponse(String sentToClient) {
  return jsonDecode(
      sentToClient.substring('data:'.length, sentToClient.indexOf('\n')));
}

List decodeResponseAsList(String serverResponse) {
  return List<String>.from(jsonDecode(
      serverResponse.substring('data:'.length, serverResponse.indexOf('\n'))));
}

Future<AtData> createRandomKeyStoreEntry(String owner, String keyName,
    SecondaryKeyStore<String, AtData?, AtMetaData?> secondaryKeyStore,
    {String? data, Metadata? commonsMetadata, DateTime? refreshAt}) async {
  AtData entry = createRandomAtData(owner,
      data: data, commonsMetadata: commonsMetadata, refreshAt: refreshAt);
  await secondaryKeyStore.put(keyName, entry);
  return (await secondaryKeyStore.get(keyName))!;
}

AtData createRandomAtData(String owner,
    {String? data, Metadata? commonsMetadata, DateTime? refreshAt}) {
  AtData atData = AtData();
  atData.data = data;
  atData.data ??= createRandomString(100);
  atData.metaData = createRandomAtMetaData(owner,
      commonsMetadata: commonsMetadata, refreshAt: refreshAt);
  return atData;
}

Metadata createRandomCommonsMetadata({bool noNullsPlease = false}) {
  Metadata md = Metadata();

  md.isEncrypted = createRandomBoolean();
  md.isBinary = createRandomBoolean();
  md.encoding = createRandomString(5);
  md.pubKeyCS = createRandomString(5);
  md.sharedKeyEnc = createRandomString(10);
  md.dataSignature = createRandomString(7);
  md.ccd = createRandomBoolean();
  md.ttl = createRandomPositiveInt();
  md.ttb = createRandomPositiveInt();
  md.ttr = createRandomPositiveInt();
  md.encKeyName = createRandomString(6);
  md.encAlgo = createRandomString(3);
  md.ivNonce = createRandomString(5);
  md.skeEncKeyName = createRandomString(6);
  md.skeEncAlgo = createRandomString(3);

  return md;
}

AtMetaData createRandomAtMetaData(String owner,
    {Metadata? commonsMetadata, DateTime? refreshAt}) {
  late AtMetaData md;

  if (commonsMetadata != null) {
    md = AtMetaData.fromCommonsMetadata(commonsMetadata);
  } else {
    md = AtMetaData();
    md.isEncrypted = createRandomNullableBoolean();
    md.isBinary = createRandomNullableBoolean();
    md.encoding = createRandomString(5);
    md.pubKeyCS = createRandomString(5);
    md.sharedKeyEnc = createRandomString(10);
    md.dataSignature = createRandomString(7);
    md.isCascade = createRandomNullableBoolean();
    md.ttl = createRandomNullablePositiveInt();
    md.ttb = createRandomNullablePositiveInt();
    md.ttr = createRandomNullablePositiveInt();
  }

  if (refreshAt != null) {
    md.refreshAt = refreshAt;
  }

  md.createdBy = owner;
  md.updatedBy = owner;
  DateTime now = DateTime.now().toUtcMillisecondsPrecision();
  md.createdAt = now;
  md.updatedAt = now;

  return md;
}

int createRandomPositiveInt({int maxInclusive = 100000}) {
  // We'll make it zero 20% of the time
  if (testUtilsRandom.nextInt(5) == 0) {
    return 0;
  }
  return testUtilsRandom.nextInt(maxInclusive) + 1;
}

int? createRandomNullablePositiveInt(
    {int minInclusive = 100, int maxInclusive = 100000}) {
  // We'll make it null 50% of the time
  if (testUtilsRandom.nextInt(2) == 0) {
    return null;
  }
  // We'll make it zero 10% of the time (1/5th of the remaining 50%)
  if (testUtilsRandom.nextInt(5) == 0) {
    return 0;
  }
  return testUtilsRandom.nextInt(maxInclusive - minInclusive) + minInclusive;
}

bool? createRandomNullableBoolean() {
  int i = testUtilsRandom.nextInt(3);
  if (i == 0) return null;
  if (i == 1) return false;
  return true;
}

bool createRandomBoolean() {
  int i = testUtilsRandom.nextInt(2);
  return (i == 1);
}

const String characters =
    '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_';

String createRandomString(int length) {
  return String.fromCharCodes(Iterable.generate(
      length,
      (index) =>
          characters.codeUnitAt(testUtilsRandom.nextInt(characters.length))));
}
