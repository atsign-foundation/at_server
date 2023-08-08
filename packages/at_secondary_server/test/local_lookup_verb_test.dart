import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();

  group('A group of local_lookup verb tests', () {
    test('test lookup key-value', () {
      var verb = LocalLookup();
      var command = 'llookup:@bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test lookup key-value - forAtSign with no @', () {
      var verb = LocalLookup();
      var command = 'llookup:bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'bob:email');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test lookup key-value - without forAtSign', () {
      var verb = LocalLookup();
      var command = 'llookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test lookup key-value - forAtSign is public', () {
      var verb = LocalLookup();
      var command = 'llookup:public:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test lookup key-value - cached key', () {
      var command = 'llookup:cached:@bob:email@colin';
      var handler = LocalLookupVerbHandler(mockKeyStore);
      var paramsMap = handler.parse(command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap['isCached'], 'true');
    });

    test('test local_lookup getVerb', () {
      var handler = LocalLookupVerbHandler(mockKeyStore);
      var verb = handler.getVerb();
      expect(verb is LocalLookup, true);
    });

    test('test local_lookup command accept test', () {
      var command = 'llookup:@b0b:location@colin';
      var handler = LocalLookupVerbHandler(mockKeyStore);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test llookup key-value with emojis', () {
      var verb = LocalLookup();
      var command = 'llookup:@🦄:email@🎠';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[FOR_AT_SIGN], '🦄');
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], '🎠');
    });

    test('test llookup invalid syntax with emojis', () {
      var verb = LocalLookup();
      var command = 'llookup:@🦄:email🎠';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test llookup invalid atsign', () {
      var verb = LocalLookup();
      var command = 'llookup:email@bob@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test local_lookup key- no for atSign', () {
      var verb = LocalLookup();
      var command = 'llookup:location';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test local_lookup key- invalid keyword', () {
      var verb = LocalLookup();
      var command = 'llokup:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of hive related unit test', () {
    var storageDir = '${Directory.current.path}/test/hive';
    late SecondaryKeyStoreManager keyStoreManager;
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));

    test('test local lookup with private key', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          keyStore,
          StatsNotificationService.getInstance(),
          NotificationManager.getInstance());
      var updateVerbParams = HashMap<String, String>();
      var updateResponse = Response();
      updateVerbParams.putIfAbsent(AT_KEY, () => 'phone');
      updateVerbParams.putIfAbsent(AT_SIGN, () => 'test_user_1');
      updateVerbParams.putIfAbsent(AT_VALUE, () => '1234');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLookup Verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@test_user_1');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'phone');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, '1234');
    });

    test('test local lookup with public key', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          keyStore,
          StatsNotificationService.getInstance(),
          NotificationManager.getInstance());
      var updateVerbParams = HashMap<String, String>();
      var updateResponse = Response();
      updateVerbParams.putIfAbsent(AT_KEY, () => 'location');
      updateVerbParams.putIfAbsent(AT_SIGN, () => 'test_user_1');
      updateVerbParams.putIfAbsent(AT_VALUE, () => 'India');
      updateVerbParams.putIfAbsent(PUBLIC_SCOPE_PARAM, () => 'public');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLookup Verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@test_user_1');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      localLookVerbParam.putIfAbsent('isPublic', () => 'true');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, 'India');
    });
    tearDown(() async => await tearDownFunc());
  });

  group('A group of tests related APKAM enrollment', () {
    Response response = Response();
    String enrollmentId = Uuid().v4();
    setUp(() async {
      await verbTestsSetUp();
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
    });

    test(
        'A test to verify llookup verb is allowed in all namespace when access is *:r',
        () async {
      // Update a key with wavi namespace
      String updateCommand = 'update:$alice:phone.wavi$alice 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      // Since the namespace have only read access, setting the
      // enrollmentId to connection after update
      inboundConnection.metadata.enrollmentId = enrollmentId;
      // Local Lookup a key with wavi namespace
      String llookupCommand = 'llookup:$alice:phone.wavi$alice';
      HashMap<String, String?> llookupVerbParams =
          getVerbParam(VerbSyntax.llookup, llookupCommand);
      LocalLookupVerbHandler localLookupVerbHandler =
          LocalLookupVerbHandler(secondaryKeyStore);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, '123');
    });
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign)!;
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@test_user_1', commitLogPath: storageDir);
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  await AtAccessLogManagerImpl.getInstance()
      .getAccessLog('@test_user_1', accessLogPath: storageDir);
  final notificationStore = AtNotificationKeystore.getInstance();
  notificationStore.currentAtSign = '@test_user_1';
  await notificationStore.init(storageDir);
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
