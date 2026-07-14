import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  verbTestsSetUpLogging();

  group('A group of local_lookup verb tests', () {
    setUp(() async {
      await verbTestsSetUpAll();
      await verbTestsSetUp();
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('test lookup key-value', () {
      var verb = LocalLookup();
      var command = 'llookup:@bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], 'colin');
    });

    test('test lookup key-value - forAtSign with no @', () {
      var verb = LocalLookup();
      var command = 'llookup:bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'bob:email');
      expect(paramsMap[AtConstants.atSign], 'colin');
    });

    test('test lookup key-value - without forAtSign', () {
      var verb = LocalLookup();
      var command = 'llookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], 'colin');
    });

    test('test lookup key-value - forAtSign is public', () {
      var verb = LocalLookup();
      var command = 'llookup:public:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], 'colin');
    });

    test('test lookup key-value - cached key', () {
      var command = 'llookup:cached:@bob:email@colin';
      var handler = LocalLookupVerbHandler(keyValueStore, enMgr);
      var paramsMap = handler.parse(command);
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], 'colin');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap['isCached'], 'true');
    });

    test('test local_lookup getVerb', () {
      var handler = LocalLookupVerbHandler(keyValueStore, enMgr);
      var verb = handler.getVerb();
      expect(verb is LocalLookup, true);
    });

    test('test local_lookup command accept test', () {
      var command = 'llookup:@b0b:location@colin';
      var handler = LocalLookupVerbHandler(keyValueStore, enMgr);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test llookup key-value with emojis', () {
      var verb = LocalLookup();
      var command = 'llookup:@🦄:email@🎠';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.forAtSign], '🦄');
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], '🎠');
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
      var command = 'llokup:location$alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of hive related unit test', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('test local lookup with private key', () async {
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyValueStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyValueStore, mockOutboundClientManager,
          accessLog: atAccessLog, disablePqAuth: true);
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = DummyInboundConnection()
        ..metaData.sessionID = inBoundSessionId;
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => alice.substring(1));
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst(RegExp('^data:'), '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler =
          CramVerbHandler(keyValueStore, accessLog: atAccessLog);
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata = atConnection.metaData;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      var updateVerbParams = HashMap<String, String>();
      var updateResponse = Response();
      updateVerbParams.putIfAbsent(AtConstants.atKey, () => 'phone');
      updateVerbParams.putIfAbsent(
          AtConstants.atSign, () => alice.substring(1));
      updateVerbParams.putIfAbsent(AtConstants.atValue, () => '1234');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLookup Verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyValueStore, enMgr);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AtConstants.atSign, () => alice);
      localLookVerbParam.putIfAbsent(AtConstants.atKey, () => 'phone');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, '1234');
    });

    test('test local lookup with public key', () async {
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyValueStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyValueStore, mockOutboundClientManager,
          accessLog: atAccessLog, disablePqAuth: true);
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = DummyInboundConnection()
        ..metaData.sessionID = inBoundSessionId;
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => alice.substring(1));
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst(RegExp('^data:'), '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler =
          CramVerbHandler(keyValueStore, accessLog: atAccessLog);
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata = atConnection.metaData;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      var updateVerbParams = HashMap<String, String>();
      var updateResponse = Response();
      updateVerbParams.putIfAbsent(AtConstants.atKey, () => 'location');
      updateVerbParams.putIfAbsent(
          AtConstants.atSign, () => alice.substring(1));
      updateVerbParams.putIfAbsent(AtConstants.atValue, () => 'India');
      updateVerbParams.putIfAbsent(
          AtConstants.publicScopeParam, () => 'public');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLookup Verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyValueStore, enMgr);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AtConstants.atSign, () => alice);
      localLookVerbParam.putIfAbsent(AtConstants.atKey, () => 'location');
      localLookVerbParam.putIfAbsent('isPublic', () => 'true');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, 'India');
    });
  });

  group('A group of tests related APKAM enrollment and authorization', () {
    setUp(() async {
      await verbTestsSetUp();
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    Response response = Response();
    String enrollmentId = Uuid().v4();

    test(
        'A test to verify llookup verb is allowed in all namespace when access is *:r',
        () async {
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // Update a key with wavi namespace
      String updateCommand = 'update:$alice:phone.wavi$alice 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      // Update a key with buzz namespace
      updateCommand = 'update:$alice:mobile.buzz$alice 456';
      updateVerbParams = getVerbParam(VerbSyntax.update, updateCommand);
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
          LocalLookupVerbHandler(keyValueStore, enMgr);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, '123');
      // Local Lookup a key with buzz namespace
      llookupCommand = 'llookup:$alice:mobile.buzz$alice';
      llookupVerbParams = getVerbParam(VerbSyntax.llookup, llookupCommand);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, '456');
    });

    test(
        'A test to verify llookup verb of a at_contact.buzz namespace is allowed when namespace is buzz ',
        () async {
      final enrollJson = {
        'sessionId': '123',
        'appName': 'buzz',
        'deviceName': 'pixel',
        'namespaces': {'buzz': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // Update a key with buzz namespace
      String updateCommand =
          'update:at_connections.bob.alice.at_contact.buzz$alice bob';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      // Local Lookup a key with at_contact.buzz namespace
      String llookupCommand =
          'llookup:at_connections.bob.alice.at_contact.buzz$alice';
      HashMap<String, String?> llookupVerbParams =
          getVerbParam(VerbSyntax.llookup, llookupCommand);
      LocalLookupVerbHandler localLookupVerbHandler =
          LocalLookupVerbHandler(keyValueStore, enMgr);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, 'bob');
    });

    test(
        'A test to verify llookup verb of a at_contact.buzz namespace is allowed when namespace is at_contact.buzz ',
        () async {
      final enrollJson = {
        'sessionId': '123',
        'appName': 'buzz',
        'deviceName': 'pixel',
        'namespaces': {'at_contact.buzz': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // Update a key with at_contact.buzz namespace
      String updateCommand =
          'update:at_connections.bob.alice.at_contact.buzz$alice bob';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      // Local Lookup a key with at_contact.buzz namespace
      String llookupCommand =
          'llookup:at_connections.bob.alice.at_contact.buzz$alice';
      HashMap<String, String?> llookupVerbParams =
          getVerbParam(VerbSyntax.llookup, llookupCommand);
      LocalLookupVerbHandler localLookupVerbHandler =
          LocalLookupVerbHandler(keyValueStore, enMgr);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, 'bob');
    });

    test(
        'A test to verify llookup verb throws exception when namespace is not authorized',
        () async {
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'r'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      // Update a key with buzz namespace
      String updateCommand = 'update:$alice:mobile.buzz$alice 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      // Since the namespace have only read access, setting the
      // enrollmentId to connection after update
      inboundConnection.metadata.enrollmentId = enrollmentId;
      // Local Lookup a key with wavi namespace
      String llookupCommand = 'llookup:$alice:mobile.buzz$alice';
      HashMap<String, String?> llookupVerbParams =
          getVerbParam(VerbSyntax.llookup, llookupCommand);
      LocalLookupVerbHandler localLookupVerbHandler =
          LocalLookupVerbHandler(keyValueStore, enMgr);
      expect(
          () async => await localLookupVerbHandler.processVerb(
              response, llookupVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID $enrollmentId is not authorized to llookup key: $alice:mobile.buzz$alice')));
    });

    test('A test to verify read access is allowed if key is a reserved key',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      String updateCommand = 'update:$bob:shared_key$alice some shared value';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.isError, false);
      expect(response.data, isNotNull);
      var llookupCommand = 'llookup:$bob:shared_key$alice';
      var llookupVerbParams = getVerbParam(VerbSyntax.llookup, llookupCommand);
      LocalLookupVerbHandler localLookupVerbHandler =
          LocalLookupVerbHandler(keyValueStore, enMgr);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, 'some shared value');
    });

    test(
        'A test to verify read access is allowed on a reserved key for an enrollment with a specific namespace access',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage$alice';
      await keyValueStore.put(keyName, AtData()..data = jsonEncode(enrollJson));
      String updateCommand = 'update:$bob:shared_key$alice 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
      var llookupCommand = 'llookup:$bob:shared_key$alice';
      var llookupVerbParams = getVerbParam(VerbSyntax.llookup, llookupCommand);
      LocalLookupVerbHandler localLookupVerbHandler =
          LocalLookupVerbHandler(keyValueStore, enMgr);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, '123');
    });
    test(
        'A test to verify read access is allowed on a key without a namespace for an enrollment with * namespace access',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
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
      String updateCommand = 'update:$alice:secret_data$alice 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
      var llookupCommand = 'llookup:$alice:secret_data$alice';
      var llookupVerbParams = getVerbParam(VerbSyntax.llookup, llookupCommand);
      LocalLookupVerbHandler localLookupVerbHandler =
          LocalLookupVerbHandler(keyValueStore, enMgr);
      await localLookupVerbHandler.processVerb(
          response, llookupVerbParams, inboundConnection);
      expect(response.data, '123');
    });
    test(
        'A test to verify read access is denied to a key without a namespace for an enrollment with specific namespace access',
        () async {
      String testKey = '$alice:testKeyLlookupTest$alice';
      String firstEnrollmentId = Uuid().v4();
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = firstEnrollmentId;
      // create an enrollment(should have * access) and update key without namespace
      var firstEnrollmentKey =
          '$firstEnrollmentId.new.enrollments.__manage$alice';
      final firstEnrollJson = {
        'sessionId': '19867',
        'appName': 'wavi_123',
        'deviceName': 'pixel7a',
        'namespaces': {'*': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await keyValueStore.put(
          firstEnrollmentKey, AtData()..data = jsonEncode(firstEnrollJson));
      // update key using first enrollment that has * access
      String updateCommand = 'update:$testKey 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);

      // create an enrollment with wavi namespace and llookup the key
      String secondEnrollmentId = Uuid().v4();
      String secondEnrollmentKey =
          '$secondEnrollmentId.new.enrollments.__manage$alice';
      inboundConnection.metadata.enrollmentId = secondEnrollmentId;
      final secondEnrollJson = {
        'sessionId': '18969',
        'appName': 'wavi_456',
        'deviceName': 'pixel6a',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await keyValueStore.put(
          secondEnrollmentKey, AtData()..data = jsonEncode(secondEnrollJson));

      LocalLookupVerbHandler llookupVerbHandler =
          LocalLookupVerbHandler(keyValueStore, enMgr);
      String lookupCommand = 'llookup:$testKey';
      expect(
          await llookupVerbHandler.isAuthorized(inboundConnection.metadata,
              atKey: testKey),
          false);
      expect(
          () => llookupVerbHandler.processInternal(
              lookupCommand, inboundConnection),
          throwsA(predicate((e) => e is UnAuthorizedException)));
    });
  });

  group(
      'A of tests to verify local-lookup a key when enrollment is pending/revoke/denied state throws exception',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    tearDown(() async {
      await verbTestsTearDown();
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
        await keyValueStore.put('$enrollmentId.new.enrollments.__manage$alice',
            AtData()..data = jsonEncode(enrollJson));
        inboundConnection.metadata.enrollmentId = enrollmentId;
        String llookupCommand = 'llookup:$alice:dummykey.wavi$alice';
        HashMap<String, String?> localLookupVerbParams =
            getVerbParam(VerbSyntax.llookup, llookupCommand);
        LocalLookupVerbHandler localLookupVerbHandler =
            LocalLookupVerbHandler(keyValueStore, enMgr);
        expect(
            () async => await localLookupVerbHandler.processVerb(
                response, localLookupVerbParams, inboundConnection),
            throwsA(predicate((dynamic e) =>
                e is UnAuthorizedException &&
                e.message ==
                    'Connection with enrollment ID $enrollmentId is not authorized to llookup key: $alice:dummykey.wavi$alice')));
      });
    }
  });
}
