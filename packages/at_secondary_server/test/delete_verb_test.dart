import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'assets/test_config_util.dart';
import 'test_utils.dart';

void main() {
  setUpAll(() async {
    await verbTestsSetUp();
  });
  group('A group of delete verb tests', () {
    test('test delete key-value', () {
      var verb = Delete();
      var command = 'delete:@bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atSign], 'colin');
    });

    test('test delete getVerb', () {
      var handler = DeleteVerbHandler(
          secondaryKeyStore, StatsNotificationService.getInstance());
      var verb = handler.getVerb();
      expect(verb is Delete, true);
    });

    test('test delete command accept test', () {
      var command = 'delete:@bob:email@colin';
      var handler = DeleteVerbHandler(
          secondaryKeyStore, StatsNotificationService.getInstance());
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test delete command command with upper case and spaces', () {
      var command = 'DEL ETE:@bob:email@colin';
      command = SecondaryUtil.convertCommand(command);
      var handler = DeleteVerbHandler(
          secondaryKeyStore, StatsNotificationService.getInstance());
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test delete key-invalid keyword', () {
      var verb = Delete();
      var command = 'delet';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test delete key-with emoji', () {
      var verb = Delete();
      var command = 'delete:@🦄:phone@🎠';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'phone');
      expect(paramsMap[AtConstants.forAtSign], '🦄');
      expect(paramsMap[AtConstants.atSign], '🎠');
    });

    test('test delete key-with public and emoji', () {
      var verb = Delete();
      var command = 'delete:public:phone@🎠';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'phone');
      expect(paramsMap[AtConstants.atSign], '🎠');
    });

    test('test delete key-with public and emoji', () {
      var verb = Delete();
      var command = 'delete:phone@🎠';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'phone');
      expect(paramsMap[AtConstants.atSign], '🎠');
    });

    test('test delete-key with no atsign', () {
      var verb = Delete();
      var command = 'delete:privatekey:at_secret';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'privatekey:at_secret');
    });
  });

  group('verify deletion of protected keys', () {
    late DeleteVerbHandler handler;
    setUp(() async {
      await verbTestsSetUp();
      handler = DeleteVerbHandler(
          secondaryKeyStore, StatsNotificationService.getInstance());
    });

    test('verify deletion of signing public key throws exception', () {
      inboundConnection.metadata.isAuthenticated = true;
      var command = 'delete:${AtConstants.atSigningPublicKey}@alice';
      expect(
          () => handler.processInternal(command, inboundConnection),
          throwsA(
              predicate((exception) => exception is UnAuthorizedException)));
    });

    test('verify deletion of signing private key throws exception', () {
      inboundConnection.metadata.isAuthenticated = true;
      var command = 'delete:@alice:${AtConstants.atSigningPrivateKey}@alice';
      expect(
          () => handler.processInternal(command, inboundConnection),
          throwsA(
              predicate((exception) => exception is UnAuthorizedException)));
    });

    test('verify deletion of encryption public key throws exception', () {
      inboundConnection.metadata.isAuthenticated = true;
      var command = 'delete:${AtConstants.atEncryptionPublicKey}@alice';
      expect(
          () async => await handler.processInternal(command, inboundConnection),
          throwsA(
              predicate((exception) => exception is UnAuthorizedException)));
    });

    // the following test throws a syntax exception since delete verb handler
    // expects a key to contain its atsign; but at_pkam_publickey does not
    test('verify deletion of pkam public key throws exception', () {
      inboundConnection.metadata.isAuthenticated = true;
      var command = 'delete:${AtConstants.atPkamPublicKey}';
      expect(
          () => handler.processInternal(command, inboundConnection),
          throwsA(
              predicate((exception) => exception is InvalidSyntaxException)));
    });

    test('verify deletion of cached encryption public key', () async {
      inboundConnection.metadata.isAuthenticated = true;
      var command = 'delete:cached:${AtConstants.atEncryptionPublicKey}@alice';
      Response response =
          await handler.processInternal(command, inboundConnection);
      // expected response.data is an integer
      // parsing data without exception should indicate that response is an int
      expect(int.parse(response.data!).runtimeType, int);
      expect(response.isError, false);
    });

    test('verify deletion of cached signing private key', () async {
      inboundConnection.metadata.isAuthenticated = true;
      var command =
          'delete:cached:@alice:${AtConstants.atSigningPrivateKey}@alice';
      Response response =
          await handler.processInternal(command, inboundConnection);
      expect(int.parse(response.data!).runtimeType, int);
      expect(response.isError, false);
    });

    test('verify deletion of signing public key', () async {
      inboundConnection.metadata.isAuthenticated = true;
      var command = 'delete:cached:${AtConstants.atSigningPublicKey}@alice';
      Response response =
          await handler.processInternal(command, inboundConnection);
      expect(int.parse(response.data!).runtimeType, int);
      expect(response.isError, false);
    });
  });

  group(
      'Tests to verify if protected keys from config.yaml augment the server list of protected keys',
      () {
    final Set<String> serverProtectedKeys = {
      'signing_publickey<@atsign>',
      'signing_privatekey<@atsign>',
      'publickey<@atsign>',
      'at_pkam_publickey'
    };

    test('Verify with test_config_yaml1 that has 3 additional protected keys',
        () {
      TestConfigUtil.setTestConfig(1);
      expect(AtSecondaryConfig.protectedKeys.length, 7);
      assert(AtSecondaryConfig.protectedKeys.containsAll(serverProtectedKeys));
      TestConfigUtil.resetTestConfig();
    });

    test('Verify with test_config_yaml2 that has 2 additional protected keys',
        () {
      TestConfigUtil.setTestConfig(2);
      expect(AtSecondaryConfig.protectedKeys.length, 6);
      assert(AtSecondaryConfig.protectedKeys.containsAll(serverProtectedKeys));
      TestConfigUtil.resetTestConfig();
    });

    test('Verify with test_config_yaml3 that has 0 additional protected keys',
        () {
      TestConfigUtil.setTestConfig(3);
      expect(AtSecondaryConfig.protectedKeys.length, 4);
      assert(AtSecondaryConfig.protectedKeys.containsAll(serverProtectedKeys));
      TestConfigUtil.resetTestConfig();
    });
  });

  group('A group of tests related to APKAM enrollment and authorization', () {
    Response response = Response();
    String enrollmentId;

    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify delete verb is allowed in all namespace when access is *:rw',
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
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      // Delete a key with wavi namespace
      String deleteCommand = 'delete:$alice:phone.wavi$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      await deleteVerbHandler.processVerb(
          response, deleteVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      // Delete a key with buzz namespace
      deleteCommand = 'delete:$alice:phone.buzz$alice';
      deleteVerbParams = getVerbParam(VerbSyntax.delete, deleteCommand);
      deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      await deleteVerbHandler.processVerb(
          response, deleteVerbParams, inboundConnection);
      expect(response.data, isNotNull);
    });

    test(
        'A test to verify delete verb is not allowed when enrollment is not authorized for write operations',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
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

      String deleteCommand = 'delete:dummykey.wavi$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      expect(
          () async => await deleteVerbHandler.processVerb(
              response, deleteVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID $enrollmentId is not authorized to delete key: dummykey.wavi@alice')));
    });

    test(
        'A test to verify delete verb is not allowed when enrollment does not have write access to namespace',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      String enrollmentId = Uuid().v4();
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
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      String deleteCommand = 'delete:dummykey.wavi$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      await deleteVerbHandler.processVerb(
          response, deleteVerbParams, inboundConnection);
      expect(response.data, isNotNull);

      deleteCommand = 'delete:dummykey.buzz$alice';
      deleteVerbParams = getVerbParam(VerbSyntax.delete, deleteCommand);
      expect(
          () async => await deleteVerbHandler.processVerb(
              response, deleteVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID $enrollmentId is not authorized to delete key: dummykey.buzz@alice')));
    });

    test('A test to verify delete verb is allowed if key is a reserved key',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      String deleteCommand = 'delete:$bob:shared_key$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      await deleteVerbHandler.processVerb(
          response, deleteVerbParams, inboundConnection);
      expect(response.isError, false);
      expect(response.data, isNotNull);
    });
    test(
        'A test to verify delete is allowed on a reserved key for an enrollment with a specific namespace access',
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
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      String deleteCommand = 'delete:$bob:shared_key$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      await deleteVerbHandler.processVerb(
          response, deleteVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
    });
    test(
        'A test to verify delete is allowed on a key without a namespace for an enrollment with * namespace access',
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
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      String deleteCommand = 'delete:$alice:secretdata$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler = DeleteVerbHandler(
        secondaryKeyStore,
        statsNotificationService,
      );
      await deleteVerbHandler.processVerb(
          response, deleteVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
    });
    test(
        'A test to verify delete is denied on a key without a namespace for an enrollment with specific namespace access',
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
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      String deleteCommand = 'delete:$alice:secretdata$alice';
      HashMap<String, String?> deleteVerbParams =
          getVerbParam(VerbSyntax.delete, deleteCommand);
      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      expect(
          () async => await deleteVerbHandler.processVerb(
              response, deleteVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID $enrollmentId is not authorized to delete key: @alice:secretdata@alice')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A of tests to verify delete a key when enrollment is pending/revoke/denied state throws exception',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });
    Response response = Response();
    String enrollmentId;
    List operationList = ['pending', 'revoked', 'denied'];

    for (var operation in operationList) {
      test(
          'A test to verify when enrollment is $operation throws exception when deleting a key',
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
        String deleteCommand = 'delete:$alice:dummykey.wavi$alice';
        HashMap<String, String?> deleteVerbParams =
            getVerbParam(VerbSyntax.delete, deleteCommand);
        DeleteVerbHandler deleteVerbHandler =
            DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
        expect(
            () async => await deleteVerbHandler.processVerb(
                response, deleteVerbParams, inboundConnection),
            throwsA(predicate((dynamic e) =>
                e is UnAuthorizedException &&
                e.message ==
                    'Connection with enrollment ID $enrollmentId is not authorized to delete key: @alice:dummykey.wavi@alice')));
      });
    }
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to apkam keys expiry', () {
    Response response = Response();
    late String enrollmentId;

    setUp(() async {
      await verbTestsSetUp();
    });

    tearDown(() async => await verbTestsTearDown());

    test('A test to verify delete verb fails when apkam keys are expired',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-session', 'app-name', 'my-device', 'dummy-public-key');
      enrollDataStoreValue.namespaces = {'wavi': 'rw'};
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.approved.name);
      enrollDataStoreValue.apkamKeysExpiryDuration = Duration(milliseconds: 1);

      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName,
          AtData()
            ..data = jsonEncode(enrollDataStoreValue.toJson())
            ..metaData = (AtMetaData()..ttl = 1));

      String deleteCommand = 'delete:@alice:phone.wavi@alice';

      DeleteVerbHandler deleteVerbHandler =
          DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
      response = await deleteVerbHandler.processInternal(
          deleteCommand, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0028');
      expect(response.errorMessage,
          'The enrollment id: $enrollmentId is expired. Closing the connection');
    });
  });
}
