import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
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

void main() {
  var storageDir = Directory.current.path + '/test/hive';
  var keyStoreManager;
  setUp(() async => keyStoreManager = await setUpFunc(storageDir));

  group('A group of update accept tests', () {
    test('test update command accept test', () {
      var command = 'update:public:location@alice newyork';
      var handler = UpdateVerbHandler(null);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test update command accept negative test', () {
      var command = 'updated:public:location@alice newyork';
      var handler = UpdateVerbHandler(null);
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
      var command = 'update:public:location@alice newyork';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[FOR_AT_SIGN], isNull);
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'newyork');
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

    test('test update with multiple : in key', () {
      var verb = Update();
      var command = 'update:ttl:1:public:location:city@alice Hyderbad:TG';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location:city');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderbad:TG');
    });

    test('test update key- no atsign', () {
      var verb = Update();
      var command = 'update:location us';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
    });

    test('test update key- key with colon', () {
      var verb = Update();
      var command = 'update:location:local us';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location:local');
    });
  });

  group('A group of update verb handler test', () {
    test('test update verb handler- update', () {
      var command = 'update:location@alice us';
      AbstractVerbHandler handler = UpdateVerbHandler(null);
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
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      var verb = handler.getVerb();
      var verbParameters = handler.parse(command);

      expect(verb is Update, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters['isPublic'], 'true');
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
      var command = 'update:ttl::public:location:city@alice Hyderbad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update with ttb with no value', () {
      var verb = Update();
      var command = 'update:ttb::public:location:city@alice Hyderbad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update with two colons beside - invalid syntax', () {
      var verb = Update();
      var command = 'update::location:city@alice Hyderbad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update with @ suffixed in atsign - invalid syntax', () {
      var verb = Update();
      var command = 'update:location:city@alice@ Hyderbad:TG';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update key- no value', () {
      var verb = Update();
      var command = 'update:location@alice ';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update key- invalid keyword', () {
      var verb = Update();
      var command = 'updation:location@alice us';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update verb - no key', () {
      var verb = Update();
      var command = 'update: us';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update verb - with public and private for atSign', () {
      var verb = Update();
      var command = 'update:public:@kevin:location@bob us';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update key no value - invalid command', () {
      var command = 'update:location@alice';
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      expect(
          () => handler.parse(command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. e.g update:@alice:location@bob sanfrancisco')));
    });
  });

  group('group of positive unit test around ttl and ttb', () {
    test('test update with ttl and ttb with values', () {
      var verb = Update();
      var command =
          'update:ttl:20000:ttb:20000:public:location:city@alice Hyderbad:TG';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location:city');
      expect(paramsMap[AT_TTL], '20000');
      expect(paramsMap[AT_TTB], '20000');
      expect(paramsMap[AT_SIGN], 'alice');
      expect(paramsMap[AT_VALUE], 'Hyderbad:TG');
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
  });

  group('group of negative tests around ttl and ttb', () {
    test('ttl starting with 00', () {
      var command = 'UpDaTe:ttl:00:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign);
      handler.keyStore =
          secondaryPersistenceStore.getSecondaryKeyStoreManager().getKeyStore();
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      expect(
          () => handler.processVerb(response, verbParams, atConnection),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Valid value for TTL should be greater than or equal to 1')));
    });

    test('ttb starting with 0', () {
      var command = 'UpDaTe:ttb:00:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign);
      handler.keyStore =
          secondaryPersistenceStore.getSecondaryKeyStoreManager().getKeyStore();
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      expect(
          () => handler.processVerb(response, verbParams, atConnection),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Valid value for TTB should be greater than or equal to 1')));
    });

    test('ttl and ttb starting with 0', () {
      var command = 'UpDaTe:ttl:00:ttb:00:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      expect(() => handler.processVerb(response, verbParams, atConnection),
          throwsA(predicate((e) => e is InvalidSyntaxException)));
    });

    test('ttl with no value - invalid syntax', () {
      var command = 'UpDaTe:ttl::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      expect(
          () => handler.parse(command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. e.g update:@alice:location@bob sanfrancisco')));
    });

    test('ttb with no value - invalid syntax', () {
      var command = 'UpDaTe:ttb::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      expect(
          () => handler.parse(command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. e.g update:@alice:location@bob sanfrancisco')));
    });

    test('ttl and ttb with no value - invalid syntax', () {
      var command = 'UpDaTe:ttl::ttb::@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      expect(
          () => handler.parse(command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. e.g update:@alice:location@bob sanfrancisco')));
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
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign);
      handler.keyStore =
          secondaryPersistenceStore.getSecondaryKeyStoreManager().getKeyStore();
      var response = Response();
      var verbParams = handler.parse(command);
      var atConnection = InboundConnectionImpl(null, null);
      expect(
          () => handler.processVerb(response, verbParams, atConnection),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Valid values for TTR are -1 and greater than or equal to 1')));
    });

    test('ccd with invalid value', () {
      var command = 'UpDaTe:ttr:1000:ccd:test:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      AbstractVerbHandler handler = UpdateVerbHandler(null);
      expect(
          () => handler.parse(command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException &&
              e.message ==
                  'Invalid syntax. e.g update:@alice:location@bob sanfrancisco')));
    });
  });

  group('A group of test cases with hive', () {
    test('test update processVerb with local key', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'alice');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(keyStore);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => '@sitaram');
      updateVerbParams.putIfAbsent('atKey', () => 'location');
      updateVerbParams.putIfAbsent('value', () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent('atSign', () => '@sitaram');
      localLookVerbParam.putIfAbsent('atKey', () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, 'hyderabad');
    });

    test('test update processVerb with ttl and ttb', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'alice');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var cramVerbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var cramResponse = Response();
      await cramVerbHandler.processVerb(
          cramResponse, cramVerbParams, atConnection);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(keyStore);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent(AT_SIGN, () => '@sitaram');
      updateVerbParams.putIfAbsent(AT_KEY, () => 'location');
      updateVerbParams.putIfAbsent(AT_TTL, () => '10000');
      updateVerbParams.putIfAbsent(AT_TTB, () => '10000');
      updateVerbParams.putIfAbsent(AT_VALUE, () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLOOKUP Verb - TTB
      var localLookUpResponse_ttb = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@sitaram');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse_ttb, localLookVerbParam, atConnection);
      expect(localLookUpResponse_ttb.data, null);
      await Future.delayed(Duration(seconds: 10));
      //LLOOKUP Verb - After TTB
      var localLookUpResponse_ttb1 = Response();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@sitaram');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse_ttb1, localLookVerbParam, atConnection);
      expect(localLookUpResponse_ttb1.data, 'hyderabad');
      await Future.delayed(Duration(seconds: 10));
      //LLOOKUP Verb - After TTL
      var localLookUpResponse_ttl = Response();
      localLookVerbParam.putIfAbsent(AT_SIGN, () => '@sitaram');
      localLookVerbParam.putIfAbsent(AT_KEY, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse_ttl, localLookVerbParam, atConnection);
      expect(localLookUpResponse_ttl.data, null);
    });
  });
  tearDown(() async => await tearDownFunc());
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign);
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getHiveCommitLog('@alice', commitLogPath: storageDir);
  var persistenceManager = secondaryPersistenceStore.getPersistenceManager();
  await persistenceManager.init('@alice', storageDir);
  if (persistenceManager is HivePersistenceManager) {
    await persistenceManager.openVault('@alice');
  }
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore;
  hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager.keyStore = hiveKeyStore;
  await AtAccessLogManagerImpl.getInstance()
      .getHiveAccessLog('@alice', accessLogPath: storageDir);
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
