import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

import 'assets/test_config_util.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

class MockInboundConnection extends Mock implements InboundConnectionImpl {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
  InboundConnection mockInboundConnection = MockInboundConnection();

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

  // The following group of tests are to ensure that the protected keys cannot be deleted
  group('verify deletion of protected keys', () {
    var handler =
        DeleteVerbHandler(mockKeyStore, StatsNotificationService.getInstance());

    test('verify deletion of signing public key', () {
      var command = 'delete:$AT_SIGNING_PUBLIC_KEY@alice';
      var paramsMap = getVerbParam(Delete().syntax(), command);

      expect(
          () =>
              handler.processVerb(Response(), paramsMap, mockInboundConnection),
          throwsA(
              predicate((exception) => exception is UnAuthorizedException)));
    });

    test('verify deletion of signing private key', () {
      var command = 'delete:@alice:$AT_SIGNING_PRIVATE_KEY@alice';
      var paramsMap = getVerbParam(Delete().syntax(), command);
      expect(
          () =>
              handler.processVerb(Response(), paramsMap, mockInboundConnection),
          throwsA(
              predicate((exception) => exception is UnAuthorizedException)));
    });

    test('verify deletion of encryption public key', () {
      var command = 'delete:$AT_ENCRYPTION_PUBLIC_KEY@alice';
      var paramsMap = getVerbParam(Delete().syntax(), command);
      expect(
          () =>
              handler.processVerb(Response(), paramsMap, mockInboundConnection),
          throwsA(
              predicate((exception) => exception is UnAuthorizedException)));
    });

    // the following test throws a syntax exception since delete verb handler
    // expects a key to contain its atsign; but at_pkam_publickey does not
    test('verify deletion of pkam public key', () {
      var command = 'delete:$AT_PKAM_PUBLIC_KEY';
      try {
        var paramsMap = getVerbParam(Delete().syntax(), command);
        handler.processVerb(Response(), paramsMap, mockInboundConnection);
      } on Exception catch (exception) {
        assert(exception.toString().contains('Syntax Exception'));
      }
    });
  });

  group('Tests to verify if protected keys from config.yaml augment the server list of protected keys', (){
    final Set<String> serverProtectedKeys = {
      'signing_publickey<@atsign>',
      'signing_privatekey<@atsign>',
      'publickey<@atsign>',
      'at_pkam_publickey'
    };

    test(
        'Verify with test_config_yaml1 that has 3 additional protected keys',
            () {
          TestConfigUtil.setTestConfig(1);
          expect(AtSecondaryConfig.protectedKeys.length, 7);
          assert(AtSecondaryConfig.protectedKeys.containsAll(serverProtectedKeys));
          TestConfigUtil.resetTestConfig();
        });

    test(
        'Verify with test_config_yaml2 that has 2 additional protected keys',
            () {
          TestConfigUtil.setTestConfig(2);
          expect(AtSecondaryConfig.protectedKeys.length, 6);
          assert(AtSecondaryConfig.protectedKeys.containsAll(serverProtectedKeys));
          TestConfigUtil.resetTestConfig();
        });

    test(
        'Verify with test_config_yaml3 that has 0 additional protected keys',
            () {
          TestConfigUtil.setTestConfig(3);
          expect(AtSecondaryConfig.protectedKeys.length, 4);
          assert(AtSecondaryConfig.protectedKeys.containsAll(serverProtectedKeys));
          TestConfigUtil.resetTestConfig();
        });
  });
}
