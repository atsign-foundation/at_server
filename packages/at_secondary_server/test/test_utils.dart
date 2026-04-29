import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypton/crypton.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class MockSecondaryKeyStore extends Mock
    implements SecondaryKeyStore<String, AtData?, AtMetaData?> {
  @override
  List<Future Function(String key, {required bool skipCommit})> preRemoveHooks =
      [];
  @override
  List<Future Function(String key, {required bool skipCommit})>
      postRemoveHooks = [];
}

class MockAtNotificationKeystore extends Mock
    implements AtNotificationKeystore {}

class MockNotifyConnectionsPool extends Mock implements NotifyConnectionsPool {}

class MockOutboundClient extends Mock implements OutboundClient {}

class MockOutboundClientManager extends Mock implements OutboundClientManager {}

class MockNotificationManager extends Mock implements NotificationManager {}

class MockStatsNotificationService extends Mock
    implements StatsNotificationService {
  @override
  Future<void> writeStatsToMonitor(
      {String? latestCommitID, String? operationType}) async {}
}

class MockAtCacheManager extends Mock implements AtCacheManager {}

class MockSecondaryAddressFinder extends Mock
    implements at_lookup.SecondaryAddressFinder {}

class MockInboundConnection extends Mock implements InboundConnection {}

class FakeInboundConnection extends Fake implements InboundConnectionImpl {
  final FakeSocket socket;
  final InboundConnectionMetadata metadata;
  FakeInboundConnection(this.socket, this.metadata);

  @override
  Socket get underlying => socket;

  @override
  InboundConnectionMetadata get metaData => metadata;

  @override
  bool isInValid() {
    return false;
  }

  @override
  Future<void> close() async {}
}

class MockInboundConnectionPool extends Mock implements InboundConnectionPool {}

class MockInboundConnectionManager extends Mock
    implements InboundConnectionManager {}

class MockOutboundConnectionFactory extends Mock
    implements OutboundConnectionFactory {}

class MockOutboundConnection extends Mock implements OutboundSocketConnection {}

class MockSecureSocket extends Mock implements SecureSocket {}

class MockEnrollmentManager extends Mock implements EnrollmentManager {}

class FakeSocket extends Fake implements Socket {
  Completer completer = Completer();
  final _controller = StreamController<Uint8List>();
  bool closeCalled = false;

  void addData(String data) => _controller.add(utf8.encode(data));

  @override
  Future get done => completer.future;

  @override
  InternetAddress get remoteAddress => InternetAddress('127.0.0.1');

  @override
  int get remotePort => 9999;

  @override
  InternetAddress get address => InternetAddress('127.0.0.1');

  @override
  int get port => 5555;

  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<void> close() async {
    closeCalled = true;
  }
}

class MockStreamSubscription<T> extends Mock implements StreamSubscription<T> {}

// String alice = '@alice🛠';
Atsign alice = '@alice'.toAtsign();
Atsign bob = '@bob'.toAtsign();
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
late AtNotificationKeystore notifStore;
late NotificationManager notificationManager;
late MockStatsNotificationService statsNotificationService;
late EnrollmentManager enMgr;

late Function(dynamic data) socketOnDataFn;
// ignore: unused_local_variable
late Function() socketOnDoneFn;
// ignore: unused_local_variable
late Function(Exception e, StackTrace st) socketOnErrorFn;

String storageDir = '${Directory.current.path}/unit_test_storage';
late AtCommitLog atCommitLog;

/// Creates and persists a new approved enrollment
/// NB: Does not go through enroll verb handler, so
/// no other enrollment stuff is happening
Future<String> createAndPersistAnEnrollment(
  String app,
  String device,
  Map<String, String> namespaces,
) async {
  final id = Uuid().v4();
  final key = enMgr.buildEnrollmentKey(id);
  final enrollJson = {
    'sessionId': '123',
    'appName': app,
    'deviceName': device,
    'namespaces': namespaces,
    'apkamPublicKey': 'testPublicKeyValue',
    'requestType': 'newEnrollment',
    'approval': {'state': 'approved'}
  };
  await secondaryKeyStore.put(
    key,
    AtData()..data = jsonEncode(enrollJson),
    skipCommit: true,
  );
  return id;
}

AtSecondaryServerImpl get atServer => AtSecondaryServerImpl.getInstance();

void verbTestsSetUpLogging() {
  AtSignLogger.root_level = 'shout';
  AtSignLogger.defaultLoggingHandler = AtSignLogger.stdErrLoggingHandler;
}

verbTestsSetUpAll() async {
  verbTestsSetUpLogging();
  // Pre-warm an access log on the singleton so any test that runs before a
  // setUp can still hit it. Routed through the deprecated singleton on
  // purpose — this is bootstrap-only and matches the pre-factory shape.
  // ignore: deprecated_member_use
  await AtAccessLogManagerImpl.getInstance()
      .getAccessLog(alice, accessLogPath: storageDir);
}

verbTestsSetUp() async {
  verbTestsSetUpLogging();
  // Wire up persistence through the new factory rather than the legacy
  // singletons. The factory routes through the singletons internally
  // (Phase 1 wiring) so any test that still calls
  // *.getInstance() sees the same per-atSign instances.
  final factory =
      atServer.persistenceFactory = HiveAtPersistenceFactory();
  final config = HivePersistenceConfig(
    storagePath: storageDir,
    commitLogPath: storageDir,
    accessLogPath: storageDir,
    notificationStoragePath: storageDir,
  );
  final bundle = await factory.initialize(alice, config);

  atServer.commitLog = atCommitLog = bundle.commitLog;
  atServer.accessLog = bundle.accessLog;
  secondaryKeyStore = bundle.keyStore;

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
  atServer.inboundConnectionManager =
      InboundConnectionManager(serverAtSign: alice, poolSize: 5);
  // final inboundPool = InboundConnectionPool.getInstance();
  // inboundPool.init(5);
  // inboundPool.add(inboundConnection);

  outboundClientWithHandshake = OutboundClient(
    inboundConnection,
    bob,
    mockSecondaryAddressFinder,
    true,
    mockOutboundConnectionFactory,
  )
    ..notifyTimeoutMillis = 100
    ..lookupTimeoutMillis = 100
    ..toHost = bobHost
    ..toPort = bobPort.toString()
    ..productionMode = false;
  outboundClientWithoutHandshake = OutboundClient(
    inboundConnection,
    bob,
    mockSecondaryAddressFinder,
    false,
    mockOutboundConnectionFactory,
  )
    ..notifyTimeoutMillis = 100
    ..lookupTimeoutMillis = 100
    ..toHost = bobHost
    ..toPort = bobPort.toString()
    ..productionMode = false;

  mockOutboundClientManager = MockOutboundClientManager();
  when(() => mockOutboundClientManager.getClient(bob, any(),
      handshakeRequired: true)).thenAnswer((_) async {
    await outboundClientWithHandshake.connect();
    return outboundClientWithHandshake;
  });
  when(() => mockOutboundClientManager.getClient(bob, any(),
      handshakeRequired: false)).thenAnswer((_) async {
    await outboundClientWithoutHandshake.connect();
    return outboundClientWithoutHandshake;
  });

  AtConnectionMetaData outboundConnectionMetadata =
      OutboundConnectionMetadata();
  outboundConnectionMetadata.sessionID = 'mock-session-id';
  when(() => mockOutboundConnection.metaData)
      .thenReturn(outboundConnectionMetadata);
  when(() => mockOutboundConnection.metaData)
      .thenReturn(outboundConnectionMetadata);

  mockSecureSocket = MockSecureSocket();
  when(() => mockOutboundConnection.underlying)
      .thenAnswer((_) => mockSecureSocket);
  when(() => mockOutboundConnection.isInValid()).thenReturn(false);
  when(() => mockOutboundConnection.close()).thenAnswer((_) async => {});

  when(() => mockSecureSocket.listen(
        any(),
        onDone: any(named: "onDone"),
        onError: any(named: "onError"),
      )).thenAnswer((Invocation invocation) {
    socketOnDataFn = invocation.positionalArguments[0];
    socketOnDoneFn = invocation.namedArguments[#onDone];
    socketOnErrorFn = invocation.namedArguments[#onError];

    return MockStreamSubscription();
  });

  notifStore = atServer.notificationKeystore = bundle.notificationKeystore;

  notificationManager = atServer.notificationManager = NotificationManager(
      alice,
      notifStore,
      NotifyConnectionsPool(
          mockSecondaryAddressFinder, mockOutboundConnectionFactory));
  registerFallbackValue(AtNotificationBuilder().build());

  cacheManager = atServer.cacheManager = AtCacheManager(
    alice,
    secondaryKeyStore,
    mockOutboundClientManager,
    notificationManager,
  );

  AtSecondaryServerImpl.getInstance().secondaryKeyStore = secondaryKeyStore;
  AtSecondaryServerImpl.getInstance().outboundClientManager =
      mockOutboundClientManager;
  AtSecondaryServerImpl.getInstance().currentAtSign = alice;
  AtSecondaryServerImpl.getInstance().signingKey =
      bobServerSigningKeypair.privateKey.toString();

  AtSecondaryServerImpl.getInstance().enrollmentManager =
      enMgr = EnrollmentManager(secondaryKeyStore, alice);
  enMgr.logger.level = 'shout';
  secondaryKeyStore.preRemoveHooks.add(enMgr.preRemoveHook);

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

  statsNotificationService = MockStatsNotificationService();
}

Future<void> verbTestsTearDown() async {
  secondaryKeyStore.preRemoveHooks.clear();
  secondaryKeyStore.postRemoveHooks.clear();
  // factory.close() cascades to commit log, access log, notification
  // keystore and the Hive persistence manager, and clears the legacy
  // singletons' caches.
  await atServer.persistenceFactory.close();
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
  md.pubKeyHash = PublicKeyHash(createRandomString(6), createRandomString(5));
  md.immutable = createRandomBoolean();

  return md;
}

AtMetaData createRandomAtMetaData(String owner,
    {Metadata? commonsMetadata, DateTime? refreshAt}) {
  late AtMetaData md;

  if (!owner.startsWith('@')) {
    throw IllegalArgumentException('Invalid owner atSign $owner');
  }

  if (commonsMetadata != null) {
    md = AtMetaData.fromCommonsMetadata(commonsMetadata, owner);
  } else {
    md = AtMetaData();
    md.isEncrypted = createRandomNullableBoolean();
    md.isBinary = createRandomNullableBoolean();
    md.encoding = createRandomString(5);
    md.pubKeyCS = createRandomString(5);
    md.sharedKeyEnc = createRandomString(10);
    md.encKeyName = createRandomString(10);
    md.dataSignature = createRandomString(7);
    md.isCascade = createRandomNullableBoolean();
    md.ttl = createRandomNullablePositiveInt();
    md.ttb = createRandomNullablePositiveInt();
    md.ttr = createRandomNullablePositiveInt();
    md.pubKeyHash = PublicKeyHash(createRandomString(6), createRandomString(4));
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

const List<String> unauthenticatedTopLevelCommands = [
  'from:@alice\n',
  'cram:proof-value\n',
  'pkam:proof-value\n',
  'pol\n',
  'scan\n',
  'lookup:public:publickey@alice\n',
  'info\n',
  'noop\n',
  'enroll:request:{"appName":"wavi"}\n',
];

const List<String> authenticatedTopLevelCommands = [
  'update:public:phone@alice value\n',
  'llookup:phone@alice\n',
  'plookup:public:publickey@alice\n',
  'delete:phone@alice\n',
  'sync:1\n',
  'monitor\n',
  'otp:get\n',
  'batch:lookup:public:publickey@alice\n',
  'stats\n',
  'config:block:add:@mallory\n',
];

const List<String> subcommandsAllowedWithoutAuth = [
  'notify:status:abc123\n',
  'enroll:request:{"appName":"wavi"}\n',
];

const List<String> subcommandsRequiringAuth = [
  'keys:get:public:publickey@alice\n',
  'keys:put:public:publickey@alice\n',
  'keys:unknown:anything\n',
  'enroll:approve:{"enrollmentId":"1"}\n',
  'enroll:deny:{"enrollmentId":"1"}\n',
  'enroll:revoke:{"enrollmentId":"1"}\n',
  'enroll:unrevoke:{"enrollmentId":"1"}\n',
  'enroll:delete:{"enrollmentId":"1"}\n',
  'enroll:list\n',
  'enroll:fetch:1\n',
];

const List<String> representativeListenerCommands = [
  'from:@alice\n',
  'cram:proof-value\n',
  'pkam:proof-value\n',
  'pol\n',
  'scan:showhidden:true:@alice\n',
  'lookup:public:publickey@alice\n',
  'plookup:public:publickey@alice\n',
  'info\n',
  'noop\n',
  'enroll:request:{"appName":"wavi","deviceName":"iphone","namespaces":{"wavi":"rw"},"otp":"<otp>","apkamPublicKey":"<apkamPublicKey>"}\n',
  'update:public:phone@alice +14165551212\n',
  'llookup:phone@alice\n',
  'delete:phone@alice\n',
  'sync:1\n',
  'notify:@bob:phone@alice\n',
  'notify:status:1\n',
  'notify:remove:1\n',
  'notify:update:1\n',
  'notify:all:true\n',
  'monitor\n',
  'otp:get\n',
  'keys:get:public:publickey@alice\n',
  'keys:put:public:publickey@alice:value\n',
  'batch:lookup:public:publickey@alice\n',
  'stats\n',
  'config:block:add:@mallory\n',
];
