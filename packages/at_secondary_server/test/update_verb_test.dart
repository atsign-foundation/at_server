import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_builders.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

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
      var handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test update command accept negative test', () {
      var command = 'updated:public:location@alice new york';
      var handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
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
      expect(() => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException && e.message == 'Syntax Exception')));
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
      expect(() => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) => e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of update verb handler test', () {
    test('test update verb handler- update', () {
      var command = 'update:location@alice us';
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
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
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
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
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
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
      AbstractVerbHandler handler = UpdateVerbHandler(keyStore, NotificationManager.getInstance());
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
      AbstractVerbHandler handler = UpdateVerbHandler(keyStore, NotificationManager.getInstance());
      Map parsed = handler.parse(command);
      expect(parsed['ttb'], '-1');
    });

    test('ttl and ttb starting with negative value -1', () {
      var command = 'update:ttl:-1:ttb:-1:@bob:location.test@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
      Map parsed = handler.parse(command);
      expect (parsed['ttl'], '-1');
      expect (parsed['ttb'], '-1');
    });

    test('ttl with no value - invalid syntax', () {
      var command = 'UpDaTe:ttl::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
      expect(
              () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
          e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. ${handler.getVerb().usage()}')));
    });

    test('ttb with no value - invalid syntax', () {
      var command = 'UpDaTe:ttb::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
      expect(
              () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
          e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. ${handler.getVerb().usage()}')));
    });

    test('ttl and ttb with no value - invalid syntax', () {
      var command = 'UpDaTe:ttl::ttb::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
      expect(
              () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
          e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. ${handler.getVerb().usage()}')));
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
      AbstractVerbHandler handler = UpdateVerbHandler(keyStore, NotificationManager.getInstance());
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
      AbstractVerbHandler handler = UpdateVerbHandler(mockKeyStore, NotificationManager.getInstance());
      expect(
              () => handler.parse(command),
          throwsA(predicate((dynamic e) =>
          e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. ${handler.getVerb().usage()}')));
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
      var updateVerbHandler = UpdateVerbHandler(secondaryKeyStore, NotificationManager.getInstance());
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
      var updateVerbHandler = UpdateVerbHandler(secondaryKeyStore, NotificationManager.getInstance());
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
      var updateVerbHandler = UpdateVerbHandler(secondaryKeyStore, NotificationManager.getInstance());
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
  });

  group('update verb tests with metadata', () {
    test('update with all metadata', () async {
      var pubKeyCS =
          'the_checksum_of_the_public_key_used_to_encrypted_the_AES_key';
      var ske =
          'the_AES_key__encrypted_with_some_public_key__encoded_as_base64';
      var skeEncKeyName = 'key_45678.__public_keys.__global';
      var skeEncAlgo = 'ECC/SomeCurveName/blah';
      var atKey = 'email.wavi';
      var atValue = 'alice@atsign.com';
      var updateBuilder = UpdateVerbBuilder()
        ..value = atValue
        ..atKey = atKey
        ..sharedBy = alice
        ..sharedWith = bob
        ..pubKeyChecksum = pubKeyCS
        ..sharedKeyEncrypted = ske
        ..skeEncKeyName = skeEncKeyName
        ..skeEncAlgo = skeEncAlgo;
      var updateCommand = updateBuilder.buildCommand().trim();
      expect(
          updateCommand,
          'update'
              ':sharedKeyEnc:$ske'
              ':pubKeyCS:$pubKeyCS'
              ':skeEncKeyName:$skeEncKeyName'
              ':skeEncAlgo:$skeEncAlgo'
              ':$bob:$atKey$alice $atValue');

      // We're going to
      // * do an update
      // * verify via llookup
      // * update just the value
      // * verify via llookup
      // * update just some of the metadata
      // * verify via llookup
      // * update the value and some of the metadata
      // * verify via llookup
      inboundConnection.metadata.isAuthenticated = true;
      // inboundConnection.metadata.self = true;
      UpdateVerbHandler updateHandler = UpdateVerbHandler(secondaryKeyStore, NotificationManager.getInstance());
      await updateHandler.process(updateCommand, inboundConnection);

      LocalLookupVerbHandler llookupHandler = LocalLookupVerbHandler(secondaryKeyStore);
      await llookupHandler.process('llookup:all:$bob:$atKey$alice', inboundConnection);
      Map mapSentToClient = decodeResponse(inboundConnection.lastWrittenData!);
      expect(mapSentToClient['data']['value'], atValue);
      expect(AtMetaData.fromJson(mapSentToClient['metaData']).toCommonsMetadata(),
          updateBuilder.metadata);
      expect(mapSentToClient['key'], '$bob:$atKey$alice');

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
      AbstractVerbHandler handler = UpdateVerbHandler(keyStore, NotificationManager.getInstance());
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
      AbstractVerbHandler handler = UpdateVerbHandler(keyStore, NotificationManager.getInstance());
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      await handler.processVerb(response, verbParams, atConnection);
      expect(response.isError, false);
    });
  });
}
