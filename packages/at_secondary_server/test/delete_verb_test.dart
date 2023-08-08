import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();

  group('A group of delete verb tests', () {
    test('test delete key-value', () {
      var verb = Delete();
      var command = 'delete:@bob:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test delete getVerb', () {
      var handler = DeleteVerbHandler(
          mockKeyStore, StatsNotificationService.getInstance());
      var verb = handler.getVerb();
      expect(verb is Delete, true);
    });

    test('test delete command accept test', () {
      var command = 'delete:@bob:email@colin';
      var handler = DeleteVerbHandler(
          mockKeyStore, StatsNotificationService.getInstance());
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test delete command command with upper case and spaces', () {
      var command = 'DEL ETE:@bob:email@colin';
      command = SecondaryUtil.convertCommand(command);
      var handler = DeleteVerbHandler(
          mockKeyStore, StatsNotificationService.getInstance());
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
      expect(paramsMap[AT_KEY], 'phone');
      expect(paramsMap[FOR_AT_SIGN], '🦄');
      expect(paramsMap[AT_SIGN], '🎠');
    });

    test('test delete key-with public and emoji', () {
      var verb = Delete();
      var command = 'delete:public:phone@🎠';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'phone');
      expect(paramsMap[AT_SIGN], '🎠');
    });

    test('test delete key-with public and emoji', () {
      var verb = Delete();
      var command = 'delete:phone@🎠';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'phone');
      expect(paramsMap[AT_SIGN], '🎠');
    });

    test('test delete-key with no atsign', () {
      var verb = Delete();
      var command = 'delete:privatekey:at_secret';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'privatekey:at_secret');
    });
  });

  group('A group of tests related to APKAM enrollment', () {
    Response response = Response();

    group('A group of tests when enrollment have *:rw in namespace', () {
      Response response = Response();
      late String enrollmentId;

      setUp(() async {
        await verbTestsSetUp();

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
      });

      test(
          'A test to verify delete verb is allowed in all namespace when access is *:rw',
          () async {
        // Delete a key with wavi namespace
        String deleteCommand = 'delete:$alice:phone.wavi$alice 123';
        HashMap<String, String?> deleteVerbParams =
            getVerbParam(VerbSyntax.update, deleteCommand);
        DeleteVerbHandler deleteVerbHandler =
            DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
        await deleteVerbHandler.processVerb(
            response, deleteVerbParams, inboundConnection);
        expect(response.data, isNotNull);
        // Delete a key with buzz namespace
        deleteCommand = 'delete:$alice:phone.buzz$alice 123';
        deleteVerbParams = getVerbParam(VerbSyntax.update, deleteCommand);
        deleteVerbHandler =
            DeleteVerbHandler(secondaryKeyStore, statsNotificationService);
        await deleteVerbHandler.processVerb(
            response, deleteVerbParams, inboundConnection);
        expect(response.data, isNotNull);
      });
    });

    group('A group of tests when enrollment namespace have only read access',
        () {
      setUp(() async {
        await verbTestsSetUp();

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
      });
      test(
          'A test to verify delete verb is not allowed when enrollment is not authorized for write operations',
          () async {
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
                    'Enrollment Id: $enrollmentId is not authorized for delete operation on the key: dummykey.wavi@alice')));
      });
    });
  });
}
