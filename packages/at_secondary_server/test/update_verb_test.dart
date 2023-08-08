import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_builders.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
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

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group('A group of update accept tests', () {
    test('test update command accept test', () {
      var command = 'update:public:location@alice new york';
      var handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test update command accept negative test', () {
      var command = 'updated:public:location@alice new york';
      var handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      var result = handler.accept(command);
      expect(result, false);
    });
  });
  group('A group of update verb regex test', () {
    test('test update key-value', () {
      var verb = Update();
      var command = 'update:location@alice california';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[FOR_AT_SIGN], isNull);
      expect(paramsMap[AT_VALUE], 'california');
    });

    test('test update local key-value with self atsign', () {
      var verb = Update();
      var command = 'update:@alice:location@alice california';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'alice');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'california');
    });

    test('test update key-value with another user atsign', () {
      var verb = Update();
      var command = 'update:@bob:location@alice california';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'california');
    });

    test('test update local key-value with public', () {
      var verb = Update();
      var command = 'update:public:location@alice new york';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], isNull);
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'new york');
    });

    test('test update local key-value with private key', () {
      var verb = Update();
      var command =
          'update:privatekey:at_pkam_publickey MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'privatekey:at_pkam_publickey');
      expect(paramsMap[AT_VALUE], 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB');
    });

    test('test update verb with emoji', () {
      var verb = Update();
      var command = 'update:public:phone@🦄 emoji';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'phone');
      expect(paramsMap[AT_SIGN], '🦄');
      expect(paramsMap[AT_VALUE], 'emoji');
    });

    test('test update verb with emoji', () {
      var verb = Update();
      var command = 'update:@🦓:phone@🦄 emoji';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[FOR_AT_SIGN], '🦓');
      expect(paramsMap[AT_KEY], 'phone');
      expect(paramsMap[AT_SIGN], '🦄');
      expect(paramsMap[AT_VALUE], 'emoji');
    });

    test('test update with multiple : in key - should fail', () {
      var verb = Update();
      var command = 'update:ttl:1:public:location:city@alice Hyderabad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update key- no atsign', () {
      var verb = Update();
      var command = 'update:location us';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
    });

    test('test update key- key with colon - should fail', () {
      var verb = Update();
      var command = 'update:location:local us';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of update verb handler test', () {
    test('test update verb handler- update', () {
      var command = 'update:location@alice us';
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      var verbParameters = handler.parse(command);
      var verb = handler.getVerb();
      expect(verb is Update, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[FOR_AT_SIGN], null);
      expect(verbParameters[AT_KEY], 'location');
      expect(verbParameters[AT_SIGN], 'alice');
      expect(verbParameters[AT_VALUE], 'us');
    });

    test('test update verb handler- public update', () {
      var command = 'update:public:location@alice us';
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      var verb = handler.getVerb();
      var verbParameters = handler.parse(command);

      expect(verb is Update, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[PUBLIC_SCOPE_PARAM], 'public');
      expect(verbParameters[FOR_AT_SIGN], null);
      expect(verbParameters[AT_KEY], 'location');
      expect(verbParameters[AT_SIGN], 'alice');
      expect(verbParameters[AT_VALUE], 'us');
    });

    test('update verb with upper case', () {
      var verb = Update();
      var command = 'UPDATE:@bob:location@alice US';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'US');
    });

    test('update verb and value with mixed case', () {
      var verb = Update();
      var command = 'UpDaTe:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });
  });

  group('A group of update verb regex - invalid syntax', () {
    test('test update with ttl with no value', () {
      var verb = Update();
      var command = 'update:ttl::public:location:city@alice Hyderabad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update with ttb with no value', () {
      var verb = Update();
      var command = 'update:ttb::public:location:city@alice Hyderabad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update with two colons beside - invalid syntax', () {
      var verb = Update();
      var command = 'update::location:city@alice Hyderabad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update with @ suffixed in atsign - invalid syntax', () {
      var verb = Update();
      var command = 'update:location:city@alice@ Hyderabad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update key- no value', () {
      var verb = Update();
      var command = 'update:location@alice ';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update key- invalid keyword', () {
      var verb = Update();
      var command = 'updatee:location@alice us';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update verb - no key', () {
      var verb = Update();
      var command = 'update: us';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update verb - with public and private for atSign', () {
      var verb = Update();
      var command = 'update:public:@kevin:location@bob us';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update key no value - invalid command', () {
      var command = 'update:location@alice';
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      expect(
          () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'Invalid syntax. ${handler.getVerb().usage()}')));
    });
  });

  group('group of positive unit test around ttl and ttb', () {
    test('test update with ttl and ttb with values', () {
      var verb = Update();
      var command =
          'update:ttl:20000:ttb:20000:public:location.city@alice Hyderabad:TG';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location.city');
      expect(paramsMap[AT_TTL], '20000');
      expect(paramsMap[AT_TTB], '20000');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad:TG');
    });

    test('adding ttl to the update verb', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:100:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_TTL], '100');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });

    test('adding ttb to the update verb', () {
      var verb = Update();
      var command = 'UpDaTe:ttb:150:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_TTB], '150');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });

    test('adding ttl and ttb to the update verb', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:300:ttb:150:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_TTL], '300');
      expect(paramsMap[AT_TTB], '150');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });

    test('adding ttl and ttb to the update verb with public key', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:300:ttb:150:public:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_TTL], '300');
      expect(paramsMap[AT_TTB], '150');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });

    test('adding 0 ttl and ttb to the update verb with public key', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:0:ttb:0:public:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_TTL], '0');
      expect(paramsMap[AT_TTB], '0');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });
  });

  group('group of negative tests around ttl and ttb', () {
    test('ttl starting with -1', () {
      var command = 'UpDaTe:ttl:-1:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign)!;
      SecondaryKeyStore keyStore = secondaryPersistenceStore
          .getSecondaryKeyStoreManager()!
          .getKeyStore();
      AbstractVerbHandler handler = UpdateVerbHandler(
          keyStore, statsNotificationService, notificationManager);
      Map parsed = handler.parse(command);
      expect(parsed['ttl'], '-1');
    });

    test('ttb starting with -1', () {
      var command = 'UpDaTe:ttb:-1:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign)!;
      SecondaryKeyStore keyStore = secondaryPersistenceStore
          .getSecondaryKeyStoreManager()!
          .getKeyStore();
      AbstractVerbHandler handler = UpdateVerbHandler(
          keyStore, statsNotificationService, notificationManager);
      Map parsed = handler.parse(command);
      expect(parsed['ttb'], '-1');
    });

    test('ttl and ttb starting with negative value -1', () {
      var command =
          'update:ttl:-1:ttb:-1:@bob:location.test@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      Map parsed = handler.parse(command);
      expect(parsed['ttl'], '-1');
      expect(parsed['ttb'], '-1');
    });

    test('ttl with no value - invalid syntax', () {
      var command = 'UpDaTe:ttl::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      expect(
          () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'Invalid syntax. ${handler.getVerb().usage()}')));
    });

    test('ttb with no value - invalid syntax', () {
      var command = 'UpDaTe:ttb::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      expect(
          () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'Invalid syntax. ${handler.getVerb().usage()}')));
    });

    test('ttl and ttb with no value - invalid syntax', () {
      var command = 'UpDaTe:ttl::ttb::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      expect(
          () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'Invalid syntax. ${handler.getVerb().usage()}')));
    });
  });

  group('a group of positive tests around ttr and ccd', () {
    test('adding ttr and ccd true to the update verb with public key', () {
      var verb = Update();
      var command =
          'UpDaTe:ttr:1000:ccd:true:public:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_TTR], '1000');
      expect(paramsMap[CCD], 'true');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });

    test('adding ttr and ccd false to the update verb with public key', () {
      var verb = Update();
      var command =
          'UpDaTe:ttr:1000:ccd:false:public:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_TTR], '1000');
      expect(paramsMap[CCD], 'false');
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderabad,TG');
    });
  });

  group('A group of negative tests around ttr and ccd', () {
    test('ttr starting with -2', () {
      var command = 'UpDaTe:ttr:-2:ccd:true:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign)!;
      SecondaryKeyStore keyStore = secondaryPersistenceStore
          .getSecondaryKeyStoreManager()!
          .getKeyStore();
      AbstractVerbHandler handler = UpdateVerbHandler(
          keyStore, statsNotificationService, notificationManager);
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      expect(
          () => handler.processVerb(response, verbParams, atConnection),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Valid values for TTR are -1 and greater than or equal to 1')));
    });

    test('ccd with invalid value', () {
      var command = 'UpDaTe:ttr:1000:ccd:test:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      expect(
          () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException &&
              e.message == 'Invalid syntax. ${handler.getVerb().usage()}')));
    });
  });

  group('A group of test cases with hive', () {
    test('test update processVerb with local key', () async {
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await secondaryKeyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(secondaryKeyStore);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'alice');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler = CramVerbHandler(secondaryKeyStore);
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => '@alice');
      updateVerbParams.putIfAbsent('atKey', () => 'location');
      updateVerbParams.putIfAbsent('value', () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent('atSign', () => '@alice');
      localLookVerbParam.putIfAbsent('atKey', () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, 'hyderabad');
    });

    test('test update processVerb with ttl and ttb', () async {
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await secondaryKeyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(secondaryKeyStore);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'alice');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler = CramVerbHandler(secondaryKeyStore);
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();

      int ttl = 50; // in milliseconds
      int ttb = 50; // in milliseconds

      updateVerbParams.putIfAbsent(AT_SIGN, () => '@alice');
      updateVerbParams.putIfAbsent(AT_KEY, () => 'location');
      updateVerbParams.putIfAbsent(AT_TTL, () => ttl.toString());
      updateVerbParams.putIfAbsent(AT_TTB, () => ttb.toString());
      updateVerbParams.putIfAbsent(AT_VALUE, () => 'hyderabad');

      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);

      //LLOOKUP Verb - Before TTB
      var localLookUpResponseBeforeTtb = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@alice');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponseBeforeTtb, localLookVerbParam, atConnection);
      expect(localLookUpResponseBeforeTtb.data,
          null); // should be null, value has not passed ttb

      //LLOOKUP Verb - After TTB
      await Future.delayed(Duration(milliseconds: ttb));
      var localLookUpResponseAfterTtb = Response();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@alice');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponseAfterTtb, localLookVerbParam, atConnection);
      expect(localLookUpResponseAfterTtb.data,
          'hyderabad'); // after ttb has passed, the value should exist

      //LLOOKUP Verb - After TTL
      await Future.delayed(Duration(milliseconds: ttl));
      var localLookUpResponseAfterTtl = Response();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@alice');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponseAfterTtl, localLookVerbParam, atConnection);
      expect(localLookUpResponseAfterTtl.data,
          null); // after ttl has passed, the value should no longer be live
    });

    test('Test to verify reset of TTB', () async {
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await secondaryKeyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(secondaryKeyStore);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'alice');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler = CramVerbHandler(secondaryKeyStore);
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent(AT_SIGN, () => '@alice');
      updateVerbParams.putIfAbsent(AT_KEY, () => 'location');
      updateVerbParams.putIfAbsent(AT_TTB, () => '60000');
      updateVerbParams.putIfAbsent(AT_VALUE, () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLOOKUP Verb - TTB
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@alice');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, null);
      //Reset TTB
      updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent(AT_SIGN, () => '@alice');
      updateVerbParams.putIfAbsent(AT_KEY, () => 'location');
      updateVerbParams.putIfAbsent(AT_TTB, () => '0');
      updateVerbParams.putIfAbsent(AT_VALUE, () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLOOKUP Verb - After TTB
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@alice');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, 'hyderabad');
    });

    test('test auto_notify notification expiry', () async {
      SecondaryKeyStore keyStore = secondaryPersistenceStore!
          .getSecondaryKeyStoreManager()!
          .getKeyStore();
      AbstractUpdateVerbHandler.setAutoNotify(true);
      UpdateVerbHandler updateHandler = UpdateVerbHandler(
          keyStore, statsNotificationService, notificationManager);
      AtMetaData metaData = AtMetaData()..ttl = 1000;
      AtNotification? autoNotification;

      autoNotification = await updateHandler.notify('@from', '@to', 'na',
          'na-value', NotificationPriority.high, metaData);
      int ttlInMillis =
          Duration(minutes: AtSecondaryConfig.notificationExpiryInMins)
              .inMilliseconds;
      DateTime notifExpiresAt = autoNotification!.notificationDateTime!
          .toUtc()
          .add(Duration(milliseconds: ttlInMillis));

      expect(autoNotification.id, isNotNull);
      expect(autoNotification.ttl, ttlInMillis);
      //autoNotification.expiresAt and notifExpiresAt have the difference of a
      // couple of milli seconds and they cannot asserted to be equal
      // the statement below asserts that the actual expiresAt time is within
      // a range of 3000 milliseconds of the expected expiresAt
      expect(autoNotification.expiresAt!.millisecondsSinceEpoch,
          closeTo(notifExpiresAt.millisecondsSinceEpoch, 3000));
    });
  });

  group('update verb tests with metadata', () {
    doit() async {
      var pubKeyCS =
          'the_checksum_of_the_public_key_used_to_encrypted_the_AES_key';
      var ske =
          'the_AES_key__encrypted_with_some_public_key__encoded_as_base64';
      var skeEncKeyName = 'key_45678.__public_keys.__global';
      var skeEncAlgo = 'ECC/SomeCurveName/blah';
      var atKey = 'email.wavi';
      var value = 'alice@atsign.com';
      var updateBuilder = UpdateVerbBuilder()
        ..value = value
        ..atKey = atKey
        ..sharedBy = alice
        ..sharedWith = bob
        ..pubKeyChecksum = pubKeyCS
        ..sharedKeyEncrypted = ske
        ..encKeyName = 'some_key'
        ..encAlgo = 'some_algo'
        ..ivNonce = 'some_iv'
        ..skeEncKeyName = skeEncKeyName
        ..skeEncAlgo = skeEncAlgo;
      var updateCommand = updateBuilder.buildCommand().trim();
      expect(
          updateCommand,
          'update'
          ':sharedKeyEnc:$ske'
          ':pubKeyCS:$pubKeyCS'
          ':encKeyName:some_key'
          ':encAlgo:some_algo'
          ':ivNonce:some_iv'
          ':skeEncKeyName:$skeEncKeyName'
          ':skeEncAlgo:$skeEncAlgo'
          ':$bob:$atKey$alice $value');

      inboundConnection.metadata.isAuthenticated = true;

      // 1. do an update and verify via llookup
      UpdateVerbHandler updateHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateHandler.process(updateCommand, inboundConnection);

      LocalLookupVerbHandler llookupHandler =
          LocalLookupVerbHandler(secondaryKeyStore);
      await llookupHandler.process(
          'llookup:all:$bob:$atKey$alice', inboundConnection);
      Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['key'], '$bob:$atKey$alice');
      expect(mapSentToClient['data'], value);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          updateBuilder.metadata);

      // 2. update just the value and verify
      updateBuilder.value = value = 'alice@wowzer.net';
      await updateHandler.process(
          updateBuilder.buildCommand().trim(), inboundConnection);
      await llookupHandler.process(
          'llookup:all:$bob:$atKey$alice', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['key'], '$bob:$atKey$alice');
      expect(mapSentToClient['data'], value);
      expect(
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          updateBuilder.metadata);

      // 3. update just some of the metadata and verify
      // Setting few metadata to 'null' to reset them
      updateBuilder.skeEncKeyName = 'null';
      updateBuilder.skeEncAlgo = 'null';
      updateBuilder.sharedKeyEncrypted = 'null';
      updateBuilder.encAlgo = 'WOW/MUCH/ENCRYPTION';
      updateBuilder.encKeyName = 'such_secret_key';
      updateBuilder.dataSignature = 'data_signature_to_validate_public_data';
      await updateHandler.process(
          updateBuilder.buildCommand().trim(), inboundConnection);
      await llookupHandler.process(
          'llookup:all:$bob:$atKey$alice', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['key'], '$bob:$atKey$alice');
      expect(mapSentToClient['data'], value);
      var receivedMetadata =
          AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata();
      expect(receivedMetadata.encAlgo, 'WOW/MUCH/ENCRYPTION');
      expect(receivedMetadata.encKeyName, 'such_secret_key');
      // When attributes are set to String null, the metadata is reset.
      expect(receivedMetadata.sharedKeyEnc, null);
      expect(receivedMetadata.skeEncAlgo, null);
      expect(receivedMetadata.skeEncKeyName, null);

      // 4. let's update the value and a load of random metadata, and verify
      updateBuilder.atKeyObj.metadata = createRandomCommonsMetadata();
      // Setting ttb to null to test existing value is fetched and updated.
      updateBuilder.ttb = null;
      updateBuilder.dataSignature = null;
      updateBuilder.ttr = 10;
      updateBuilder.value = value = 'alice@wonder.land';
      await updateHandler.process(
          updateBuilder.buildCommand().trim(), inboundConnection);
      await llookupHandler.process(
          'llookup:all:$bob:$atKey$alice', inboundConnection);
      var sentToClient = inboundConnection.lastWrittenData!;

      mapSentToClient = decodeResponse(sentToClient);
      expect(mapSentToClient['key'], '$bob:$atKey$alice');
      expect(mapSentToClient['data'], value);
      var atMetadata = AtMetaData.fromJson(mapSentToClient['metaData']);
      expect(
          atMetadata.dataSignature, 'data_signature_to_validate_public_data');
      expect(atMetadata.ttr, 10);
      expect(atMetadata.ttb, null);

      await secondaryKeyStore.remove('$bob:$atKey$alice');
    }

    test('update with all metadata', () async {
      for (int i = 0; i < 100; i++) {
        await doit();
      }
    });

    test('A test to verify existing metadata is retained after an update',
        () async {
      var atKey = 'email.wavi';
      var value = 'alice@atsign.com';
      var updateBuilder = UpdateVerbBuilder()
        ..value = value
        ..atKey = atKey
        ..sharedBy = alice
        ..sharedWith = bob
        ..ivNonce = 'some_iv';
      var updateCommand = updateBuilder.buildCommand().trim();
      expect(
          updateCommand,
          'update'
          ':ivNonce:some_iv'
          ':$bob:$atKey$alice $value');

      inboundConnection.metadata.isAuthenticated = true;
      // 1. Do an update and verify via llookup
      UpdateVerbHandler updateHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateHandler.process(updateCommand, inboundConnection);

      LocalLookupVerbHandler llookupHandler =
          LocalLookupVerbHandler(secondaryKeyStore);
      await llookupHandler.process(
          'llookup:all:$bob:$atKey$alice', inboundConnection);
      Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['key'], '$bob:$atKey$alice');
      expect(mapSentToClient['data'], value);
      AtMetaData atMetaData = AtMetaData.fromJson(mapSentToClient['metaData']);
      expect(atMetaData.ivNonce, 'some_iv');

      // 2. Update the metadata of a different metadata attribute
      updateBuilder = UpdateVerbBuilder()
        ..value = value
        ..atKey = atKey
        ..sharedBy = alice
        ..sharedWith = bob
        ..sharedKeyEncrypted = 'shared_key_encrypted';
      updateCommand = updateBuilder.buildCommand().trim();
      updateHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateHandler.process(updateCommand, inboundConnection);

      await llookupHandler.process(
          'llookup:all:$bob:$atKey$alice', inboundConnection);
      mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['key'], '$bob:$atKey$alice');
      expect(mapSentToClient['data'], value);
      atMetaData = AtMetaData.fromJson(mapSentToClient['metaData']);
      expect(atMetaData.ivNonce, 'some_iv');
      expect(atMetaData.sharedKeyEnc, 'shared_key_encrypted');
    });
  });

  group('A group of tests to validate sharedBy atsign', () {
    test('sharedBy atsign is not equal to current atsign', () async {
      var command = 'update:phone@bob +12345';
      command = SecondaryUtil.convertCommand(command);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign)!;
      SecondaryKeyStore keyStore = secondaryPersistenceStore
          .getSecondaryKeyStoreManager()!
          .getKeyStore();
      AbstractVerbHandler handler = UpdateVerbHandler(
          keyStore, statsNotificationService, notificationManager);
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      await expectLater(
          () async =>
              await handler.processVerb(response, verbParams, atConnection),
          throwsA(predicate((dynamic e) =>
              e is InvalidAtKeyException &&
              e.message ==
                  'Invalid update command - sharedBy atsign @bob should be same as current atsign @alice')));
    });
    test('sharedBy atsign same as current atsign', () async {
      var command = 'update:phone@alice +12345';
      command = SecondaryUtil.convertCommand(command);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign)!;
      SecondaryKeyStore keyStore = secondaryPersistenceStore
          .getSecondaryKeyStoreManager()!
          .getKeyStore();
      AbstractVerbHandler handler = UpdateVerbHandler(
          keyStore, statsNotificationService, notificationManager);
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      await handler.processVerb(response, verbParams, atConnection);
      expect(response.isError, false);
    });
  });

  group('A group of tests related to APKAM enrollment', () {
    Response response = Response();
    late String enrollmentId;

    group('A group of tests when enrollment namespace have *:rw access', () {
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
          'A test to verify update verb is allowed in all namespace when access is *:rw',
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
        // Update a key with buzz namespace
        updateCommand = 'update:$alice:phone.buzz$alice 123';
        updateVerbParams = getVerbParam(VerbSyntax.update, updateCommand);
        updateVerbHandler = UpdateVerbHandler(
            secondaryKeyStore, statsNotificationService, notificationManager);
        await updateVerbHandler.processVerb(
            response, updateVerbParams, inboundConnection);
        expect(response.data, isNotNull);
      });
    });
    group('A group of tests when "*" namespace have only read access', () {
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
          'A test to verify update verb is not allowed when enrollment is not authorized for write operations',
          () async {
        String updateCommand = 'update:$alice:dummykey.wavi$alice dummyValue';
        HashMap<String, String?> updateVerbParams =
            getVerbParam(VerbSyntax.update, updateCommand);
        UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
            secondaryKeyStore, statsNotificationService, notificationManager);
        expect(
            () async => await updateVerbHandler.processVerb(
                response, updateVerbParams, inboundConnection),
            throwsA(predicate((dynamic e) =>
                e is UnAuthorizedException &&
                e.message ==
                    'Enrollment Id: $enrollmentId is not authorized for update operation on the key: @alice:dummykey.wavi@alice')));
      });

      test(
          'A test to verify update verb is not allowed when enrollment key is not found',
          () async {
        // Setting to a new enrollmentId and NOT inserting the enrollment key to
        // test enrollment key not found scenario
        enrollmentId = Uuid().v4();
        inboundConnection.metadata.enrollmentId = enrollmentId;
        String updateCommand = 'update:$alice:dummykey.wavi$alice dummyValue';
        HashMap<String, String?> updateVerbParams =
            getVerbParam(VerbSyntax.update, updateCommand);
        UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
            secondaryKeyStore, statsNotificationService, notificationManager);
        expect(
            () async => await updateVerbHandler.processVerb(
                response, updateVerbParams, inboundConnection),
            throwsA(predicate((dynamic e) =>
                e is UnAuthorizedException &&
                e.message ==
                    'Enrollment Id: $enrollmentId is not authorized for update operation on the key: @alice:dummykey.wavi@alice')));
      });
    });
  });
}
