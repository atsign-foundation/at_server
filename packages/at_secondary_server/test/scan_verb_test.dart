import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  FakeSocket mockSocket = FakeSocket();
  NotificationManager mockNotificationManager = MockNotificationManager();

  setUpAll(() {});

  group('A group of scan verb tests', () {
    setUpAll(() async {
      await verbTestsSetUp();
    });
    test('test scan getVerb', () {
      var handler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      var verb = handler.getVerb();
      expect(verb is Scan, true);
    });

    test('test scan command accept test', () {
      var command = 'scan';
      var handler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test scan key- invalid keyword', () {
      var verb = Scan();
      var command = 'scaan';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test scan verb - upper case', () {
      var command = 'SCAN';
      command = SecondaryUtil.convertCommand(command);
      var handler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test scan verb - space in between', () {
      var verb = Scan();
      var command = 'sc an';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test scan verb - invalid syntax', () {
      var command = 'scann';
      var inbound = InboundConnectionImpl(mockSocket, null);
      var defaultVerbExecutor = DefaultVerbExecutor();
      var defaultVerbHandlerManager = DefaultVerbHandlerManager(
          keyValueStore,
          mockOutboundClientManager,
          cacheManager,
          statsNotificationService,
          mockNotificationManager,
          enMgr,
          alice,
          commitLog: atCommitLog,
          accessLog: atAccessLog);

      expect(
          () => defaultVerbExecutor.execute(
              command, inbound, defaultVerbHandlerManager),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException)));
    });

    test('test scan verb with forAtSign and regular expression', () {
      var verb = Scan();
      var command = 'scan:@bob ^@kevin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.forAtSign], '@bob');
      expect(paramsMap[AtConstants.regex], '^@kevin');
    });

    test('test scan verb with emoji in forAtSign and regular expression', () {
      var verb = Scan();
      var command = 'scan:@🐼 ^@kevin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.forAtSign], '@🐼');
      expect(paramsMap[AtConstants.regex], '^@kevin');
    });
    tearDownAll(() async {
      await verbTestsTearDown();
    });
  });

  group('A group of mock tests to verify scan verb on authenticated connection',
      () {
    late ScanVerbHandler scanVerbHandler;
    late LocalLookupVerbHandler llookupVH;
    setUp(() async {
      await verbTestsSetUp();
      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      llookupVH = LocalLookupVerbHandler(keyValueStore, enMgr);
    });
    test('A test to verify all keys are returned for a simple scan', () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      inboundConnection.metaData.isAuthenticated = true;
      await keyValueStore.put(
          'public:location.wavi$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          '@bob:phone.buzz$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          '$alice:mobile.wavi$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          'selfkey.atmosphere$alice', AtData()..data = 'dummy_value');
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponse = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponse.length, 4);
      expect(scanResponse.contains('$alice:mobile.wavi$alice'), true);
      expect(scanResponse.contains('@bob:phone.buzz$alice'), true);
      expect(scanResponse.contains('public:location.wavi$alice'), true);
      expect(scanResponse.contains('selfkey.atmosphere$alice'), true);
    });

    test(
        'A test to verify only keys matching the regex are returned when regex is supplied to scan',
        () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      inboundConnection.metaData.isAuthenticated = true;
      await keyValueStore.put(
          'public:location.wavi$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          '@bob:phone.buzz$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          '$alice:mobile.wavi$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          'selfkey.atmosphere$alice', AtData()..data = 'dummy_value');
      await scanVerbHandler.process('scan wavi', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponse = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponse.length, 2);
      expect(scanResponse.contains('$alice:mobile.wavi$alice'), true);
      expect(scanResponse.contains('public:location.wavi$alice'), true);
    });

    test(
        'A test to verify public hidden keys are returned when showhidden set to true',
        () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      inboundConnection.metaData.isAuthenticated = true;
      await keyValueStore.put(
          'public:__phone.wavi$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          '_mobile.wavi$alice', AtData()..data = 'dummy_value');
      await scanVerbHandler.process('scan:showhidden:true', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponse = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponse.length, 2);
      expect(scanResponse.contains('public:__phone.wavi$alice'), true);
      expect(scanResponse.contains('_mobile.wavi$alice'), true);
    });

    test(
        'A test to verify public hidden keys are not returned when showhidden set to false',
        () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      inboundConnection.metaData.isAuthenticated = true;
      await keyValueStore.put(
          'public:__phone.wavi$alice', AtData()..data = 'dummy_value');
      await keyValueStore.put(
          '_mobile.wavi$alice', AtData()..data = 'dummy_value');
      await scanVerbHandler.process('scan:showhidden:false', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponse = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponse.length, 0);
    });

    /// Set up an enrollment with limited access
    /// Create an __atserver event
    /// Verify that scan on this enrollment will return the __atserver event
    test('Test that __atserver events are returned by scan', () async {
      String enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'my_app',
        'deviceName': 'my_device',
        'namespaces': {'my_app': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await enMgr.put(
        enrollmentId,
        AtData()..data = jsonEncode(enrollJson),
        EnrollmentStatus.approved,
      );

      inboundConnection.metaData.isAuthenticated = true;

      final event = AtSignPKChangedEvent(bob);
      // store the event for retrieval by clients
      int nowMicros = DateTime.now().microsecondsSinceEpoch;
      String keyName = '$nowMicros.events'
          '.${AtConstants.atServerReservedNamespace}'
          '@${alice.withoutAt()}';
      await keyValueStore.put(
          keyName, AtData()..data = jsonEncode(event.toJson()));

      await llookupVH.process('llookup:$keyName', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      final fetchedEvent = AtSignPKChangedEvent.fromJson(
          jsonDecode(inboundConnection.lastWrittenData!));
      expect(fetchedEvent.toJson(), event.toJson());

      await scanVerbHandler.process('scan __atserver', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponse = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponse.length, 1);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });
  });

  group('A group of tests related to pol authenticated connection', () {
    late ScanVerbHandler scanVerbHandler;
    setUp(() async {
      await verbTestsSetUp();
      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
    });

    test(
        'A test to verify keys specific to forAtSign are returned on pol authenticated connection',
        () async {
      inboundConnection.metaData.isPolAuthenticated = true;
      inboundConnection.metaData.fromAtSign = '@bob'.toAtsign();

      await keyValueStore.put(
          '@bob:phone.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          '@kevin:location.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          '@random:country.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          'public:mobile.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          'city.wavi$alice', AtData()..data = 'dummy-value');

      List<String> scanResponseKeys = await scanVerbHandler.getLocalKeys(
          inboundConnection.metaData, '.*', false, alice);
      expect(scanResponseKeys.length, 1);
      expect(scanResponseKeys[0], 'phone.wavi$alice');
    });

    test(
        'A test to verify regex applied on pol authenticated connection returns only keys specific to forAtSign that matches the regex',
        () async {
      inboundConnection.metaData.isPolAuthenticated = true;
      inboundConnection.metaData.fromAtSign = '@bob'.toAtsign();

      await keyValueStore.put(
          '@bob:phone.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          '@bob:firstname.buzz$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          '@kevin:location.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          '@random:country.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          'public:mobile.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          'city.wavi$alice', AtData()..data = 'dummy-value');

      List<String> scanResponseKeys = await scanVerbHandler.getLocalKeys(
          inboundConnection.metaData, 'wavi', false, alice);
      expect(scanResponseKeys.length, 1);
      expect(scanResponseKeys[0], 'phone.wavi$alice');
    });
    tearDown(() async {
      await verbTestsTearDown();
    });
  });

  group('A group of tests related to unauthenticated connection', () {
    late ScanVerbHandler scanVerbHandler;
    setUp(() async {
      await verbTestsSetUp();
      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
    });
    test(
        'A test to verify scan to forAtSign cannot be executed on unauthenticated connection',
        () {
      expect(
          () => scanVerbHandler.process('scan:@bob', inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message ==
                  'Scan to another atSign cannot be performed without auth')));
    });
    test(
        'A test to verify scan on unauthenticated connection returns only public keys',
        () async {
      await keyValueStore.put(
          '@bob:phone.wavi$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          'public:firstname.buzz$alice', AtData()..data = 'dummy-value');
      await keyValueStore.put(
          'city.wavi$alice', AtData()..data = 'dummy-value');
      await scanVerbHandler.process('scan', inboundConnection);

      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseKeys = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponseKeys.length, 1);
      expect(scanResponseKeys[0], 'firstname.buzz$alice');
    });
    tearDown(() async {
      await verbTestsTearDown();
    });
  });

  group('A group of APKAM enrollment tests', () {
    late ScanVerbHandler scanVerbHandler;
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify scan does not return the enrollment keys when enrollment namespace has __manage',
        () async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'__manage': 'r', 'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      await keyValueStore.put(
          'public:firstName.wavi$alice', AtData()..data = 'alice');

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      // Set enrollmentId to the inboundConnection to mimic the APKAM auth
      inboundConnection.metaData.enrollmentId = enrollmentId;
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseList = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponseList, isNotEmpty);
      expect(
          scanResponseList
              .contains('$enrollmentId.new.enrollments.__manage$alice'),
          false);
    });

    test(
        'A test to verify scan returns only the keys whose namespaces are authorized in enrollment request',
        () async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'__manage': 'r', 'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // Insert key with wavi and buzz namespace
      await keyValueStore.put('firstName.wavi$alice', AtData()..data = 'alice');
      await keyValueStore.put(
          'mobileNumber.buzz$alice', AtData()..data = '+1 434 543 3232');

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      // Set enrollmentId to the inboundConnection to mimic the APKAM auth
      inboundConnection.metaData.enrollmentId = enrollmentId;
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseList = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponseList.length, 1);
      expect(scanResponseList[0], 'firstname.wavi$alice');
    });

    test(
        'A test to verify scan returns enrollment keys on a CRAM authenticated connection',
        () async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      inboundConnection.metaData.authType = AuthType.cram;
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'__manage': 'r', 'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseList = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponseList.length, 1);
      expect(
          scanResponseList[0], '$enrollmentId.new.enrollments.__manage$alice');
    });

    test(
        'A LEGACY connection no longer sees enrollment keys in scan',
        () async {
      // A behaviour change of this branch, and a deployment-visible one.
      // `scan` filters on the CONNECTION'S ENROLLMENT ID being present, not on
      // auth type — so a legacy connection used to fall through to the
      // unfiltered owner view simply by having none. It now carries the
      // housekeeping enrollment's id, so it is filtered like any other
      // enrollment, and `__manage` keys drop out of its results.
      //
      // Correct rather than merely consequential: `enroll:list` is the
      // management path for enrollment records, and a legacy connection is an
      // enrollment now. But a legacy client that scanned for them will stop
      // finding them, which is why this is pinned rather than left implicit.
      //
      // ⚠️ What this does NOT prove. The enrollment id is set BY HAND below,
      // so reverting the production change that puts it there — the
      // assignment in the PKAM handler's legacy branch — leaves this green.
      // That assignment is pinned by `legacy authentication creates it and
      // CONNECTS as it` in legacy_pkam_retrofit_test.dart; this is the other
      // half, that carrying the id filters the scan.
      final otherEnrollmentId = Uuid().v4();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      inboundConnection.metaData.authType = AuthType.pkamLegacy;
      inboundConnection.metaData.enrollmentId =
          EnrollmentManager.housekeepingEnrollmentId;

      // The housekeeping enrollment, exactly as the server creates it.
      await keyValueStore.put(
          '${EnrollmentManager.housekeepingEnrollmentId}'
          '.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'legacy',
              'deviceName': 'legacy',
              'namespaces': {'*': 'rw', '__manage': 'rw'},
              'apkamPublicKey': 'the-legacy-key',
              'approval': {'state': 'approved'}
            }));
      // Another enrollment's record, and an ordinary key.
      await keyValueStore.put(
          '$otherEnrollmentId.new.enrollments.__manage$alice',
          AtData()..data = jsonEncode({'approval': {'state': 'approved'}}));
      await keyValueStore.put('phone.wavi$alice', AtData()..data = '12345');

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      await scanVerbHandler.process('scan', inboundConnection);
      final List got = jsonDecode(inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', ''));

      expect(got, contains('phone.wavi$alice'),
          reason: 'the control: it holds `*:rw`, so an ordinary key must '
              'still be visible — otherwise this test would pass on a scan '
              'that returned nothing at all');
      expect(got.any((k) => '$k'.contains('__manage')), isFalse,
          reason: 'including its OWN record: an enrollment-scoped scan '
              'excludes enrollment keys whatever the grants, and carrying an '
              'enrollment id is exactly what a legacy connection now does');
    });

    test(
        'A test to verify a *:rw enrollment does NOT see __manage keys in scan',
        () async {
      var enrollmentId = Uuid().v4();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      inboundConnection.metaData.enrollmentId = enrollmentId;

      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // An ordinary key the '*:rw' enrollment IS allowed to see.
      await keyValueStore.put('phone.wavi$alice', AtData()..data = '12345');

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseList = jsonDecode(inboundConnection.lastWrittenData!);
      // '*:rw' does not grant sight of the __manage enrollment key...
      expect(
          scanResponseList
              .contains('$enrollmentId.new.enrollments.__manage$alice'),
          false);
      // ...but ordinary keys are still visible.
      expect(scanResponseList.contains('phone.wavi$alice'), true);
    });

    test(
        'A test to verify scan returns all keys EXCEPT __manage when enrollment has *:rw access',
        () async {
      var enrollmentId = Uuid().v4();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      inboundConnection.metaData.enrollmentId = enrollmentId;

      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));

      await keyValueStore.put(
          'public:phone.wavi$alice', AtData()..data = '+455 675 6765');
      await keyValueStore.put(
          '@bob:firstName.atmosphere$alice', AtData()..data = 'Alice');
      await keyValueStore.put(
          'mobile.buzz$alice', AtData()..data = '+878 787 7679');

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseList = jsonDecode(inboundConnection.lastWrittenData!);
      // The __manage enrollment key is NOT visible to a '*:rw' enrollment.
      expect(
          scanResponseList
              .contains('$enrollmentId.new.enrollments.__manage$alice'),
          false);
      expect(
          scanResponseList.contains('@bob:firstname.atmosphere$alice'), true);

      expect(scanResponseList.contains('mobile.buzz$alice'), true);
      expect(scanResponseList.contains('public:phone.wavi$alice'), true);
    });

    test(
        'A test to verify multiple app access in enrollment buzz:r, wavi:rw, atmosphere:rw',
        () async {
      var enrollmentId = Uuid().v4();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      inboundConnection.metaData.enrollmentId = enrollmentId;

      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'buzz': 'r', 'wavi': 'rw', 'atmosphere': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // Inserting wavi
      await keyValueStore.put(
          'phone.wavi$alice', AtData()..data = '+455 677 8789');
      // Inserting buzz
      await keyValueStore.put(
          'mobile.buzz$alice', AtData()..data = '+544 545 4545');
      // Inserting atmosphere
      await keyValueStore.put(
          'firstname.atmosphere$alice', AtData()..data = 'alice');

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseList = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponseList[0], 'firstname.atmosphere$alice');
      expect(scanResponseList[1], 'mobile.buzz$alice');
      expect(scanResponseList[2], 'phone.wavi$alice');
    });

    test(
        'A test to verify keys without namespace are not returned when enrollmentId is supplied',
        () async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      var enrollmentId = Uuid().v4();
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'__manage': 'r', 'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // Insert key with wavi and buzz namespace
      await keyValueStore.put('firstName$alice', AtData()..data = 'alice');
      await keyValueStore.put(
          'mobilenumber.wavi$alice', AtData()..data = '+1 434 543 3232');
      await keyValueStore.put(
          'public:country.wavi$alice', AtData()..data = 'India');
      await keyValueStore.put('city.buzz$alice', AtData()..data = 'India');

      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      // Set enrollmentId to the inboundConnection to mimic the APKAM auth
      inboundConnection.metaData.enrollmentId = enrollmentId;
      await scanVerbHandler.process('scan', inboundConnection);
      inboundConnection.lastWrittenData = inboundConnection.lastWrittenData!
          .split('\n')[0]
          .replaceAll('data:', '');
      List scanResponseList = jsonDecode(inboundConnection.lastWrittenData!);
      expect(scanResponseList.length, 2);
      expect(scanResponseList[0], 'mobilenumber.wavi$alice');
      expect(scanResponseList[1], 'public:country.wavi$alice');
    });
    tearDown(() async => await verbTestsTearDown());
  });
}
