import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_builders.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
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
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  late SecondaryKeyStore mockKeyStore;
  late MockSocket mockSocket;

  setUpAll(() async {
    await verbTestsSetUpAll();
    mockKeyStore = MockSecondaryKeyStore();
    mockSocket = MockSocket();
    when(() => mockSocket.setOption(SocketOption.tcpNoDelay, true))
        .thenReturn(true);
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
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.forAtSign], isNull);
      expect(paramsMap[AtConstants.atValue], 'california');
    });

    test('test update local key-value with self atsign', () {
      var verb = Update();
      var command = 'update:@alice:location@alice california';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], 'alice');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'california');
    });

    test('test update key-value with another user atsign', () {
      var verb = Update();
      var command = 'update:@bob:location@alice california';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'california');
    });

    test('test update local key-value with public', () {
      var verb = Update();
      var command = 'update:public:location@alice new york';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], isNull);
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'new york');
    });

    test('test update local key-value with private key', () {
      var verb = Update();
      var command =
          'update:privatekey:at_pkam_publickey MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'privatekey:at_pkam_publickey');
      expect(paramsMap[AtConstants.atValue],
          'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB');
    });

    test('test update verb with emoji', () {
      var verb = Update();
      var command = 'update:public:phone@🦄 emoji';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'phone');
      expect(paramsMap[AtConstants.atSign], '🦄');
      expect(paramsMap[AtConstants.atValue], 'emoji');
    });

    test('test update verb with emoji', () {
      var verb = Update();
      var command = 'update:@🦓:phone@🦄 emoji';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.forAtSign], '🦓');
      expect(paramsMap[AtConstants.atKey], 'phone');
      expect(paramsMap[AtConstants.atSign], '🦄');
      expect(paramsMap[AtConstants.atValue], 'emoji');
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
      expect(paramsMap[AtConstants.atKey], 'location');
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
      expect(verbParameters[AtConstants.forAtSign], null);
      expect(verbParameters[AtConstants.atKey], 'location');
      expect(verbParameters[AtConstants.atSign], 'alice');
      expect(verbParameters[AtConstants.atValue], 'us');
    });

    test('test update verb handler- public update', () {
      var command = 'update:public:location@alice us';
      AbstractVerbHandler handler = UpdateVerbHandler(
          mockKeyStore, statsNotificationService, notificationManager);
      var verb = handler.getVerb();
      var verbParameters = handler.parse(command);

      expect(verb is Update, true);
      expect(verbParameters, isNotNull);
      expect(verbParameters[AtConstants.publicScopeParam], 'public');
      expect(verbParameters[AtConstants.forAtSign], null);
      expect(verbParameters[AtConstants.atKey], 'location');
      expect(verbParameters[AtConstants.atSign], 'alice');
      expect(verbParameters[AtConstants.atValue], 'us');
    });

    test('update verb with upper case', () {
      var verb = Update();
      var command = 'UPDATE:@bob:location@alice US';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'US');
    });

    test('update verb and value with mixed case', () {
      var verb = Update();
      var command = 'UpDaTe:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
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
      expect(paramsMap[AtConstants.atKey], 'location.city');
      expect(paramsMap[AtConstants.ttl], '20000');
      expect(paramsMap[AtConstants.ttb], '20000');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad:TG');
    });

    test('adding ttl to the update verb', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:100:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.ttl], '100');
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
    });

    test('adding ttb to the update verb', () {
      var verb = Update();
      var command = 'UpDaTe:ttb:150:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.ttb], '150');
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
    });

    test('adding ttl and ttb to the update verb', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:300:ttb:150:@bob:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.ttl], '300');
      expect(paramsMap[AtConstants.ttb], '150');
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.forAtSign], 'bob');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
    });

    test('adding ttl and ttb to the update verb with public key', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:300:ttb:150:public:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.ttl], '300');
      expect(paramsMap[AtConstants.ttb], '150');
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
    });

    test('adding 0 ttl and ttb to the update verb with public key', () {
      var verb = Update();
      var command = 'UpDaTe:ttl:0:ttb:0:public:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.ttl], '0');
      expect(paramsMap[AtConstants.ttb], '0');
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
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
      expect(paramsMap[AtConstants.ttr], '1000');
      expect(paramsMap[AtConstants.ccd], 'true');
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
    });

    test('adding ttr and ccd false to the update verb with public key', () {
      var verb = Update();
      var command =
          'UpDaTe:ttr:1000:ccd:false:public:location@alice Hyderabad,TG';
      command = SecondaryUtil.convertCommand(command);
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.ttr], '1000');
      expect(paramsMap[AtConstants.ccd], 'false');
      expect(paramsMap[AtConstants.atKey], 'location');
      expect(paramsMap[AtConstants.atSign], 'alice');
      expect(paramsMap[AtConstants.atValue], 'Hyderabad,TG');
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
      var atConnection = InboundConnectionImpl(mockSocket, null);
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
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
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
          atConnection.metaData as InboundConnectionMetadata;
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
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
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
          atConnection.metaData as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();

      int ttl = 50; // in milliseconds
      int ttb = 50; // in milliseconds

      updateVerbParams.putIfAbsent(AtConstants.atSign, () => '@alice');
      updateVerbParams.putIfAbsent(AtConstants.atKey, () => 'location');
      updateVerbParams.putIfAbsent(AtConstants.ttl, () => ttl.toString());
      updateVerbParams.putIfAbsent(AtConstants.ttb, () => ttb.toString());
      updateVerbParams.putIfAbsent(AtConstants.atValue, () => 'hyderabad');

      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);

      //LLOOKUP Verb - Before TTB
      var localLookUpResponseBeforeTtb = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AtConstants.atSign, () => '@alice');
      localLookVerbParam.putIfAbsent(AtConstants.atKey, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponseBeforeTtb, localLookVerbParam, atConnection);
      expect(localLookUpResponseBeforeTtb.data,
          null); // should be null, value has not passed ttb

      //LLOOKUP Verb - After TTB
      await Future.delayed(Duration(milliseconds: ttb));
      var localLookUpResponseAfterTtb = Response();
      localLookVerbParam.putIfAbsent(AtConstants.atSign, () => '@alice');
      localLookVerbParam.putIfAbsent(AtConstants.atKey, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponseAfterTtb, localLookVerbParam, atConnection);
      expect(localLookUpResponseAfterTtb.data,
          'hyderabad'); // after ttb has passed, the value should exist

      //LLOOKUP Verb - After TTL
      await Future.delayed(Duration(milliseconds: ttl));
      var localLookUpResponseAfterTtl = Response();
      localLookVerbParam.putIfAbsent(AtConstants.atSign, () => '@alice');
      localLookVerbParam.putIfAbsent(AtConstants.atKey, () => 'location');
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
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
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
          atConnection.metaData as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent(AtConstants.atSign, () => '@alice');
      updateVerbParams.putIfAbsent(AtConstants.atKey, () => 'location');
      updateVerbParams.putIfAbsent(AtConstants.ttb, () => '60000');
      updateVerbParams.putIfAbsent(AtConstants.atValue, () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLOOKUP Verb - TTB
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent(AtConstants.atSign, () => '@alice');
      localLookVerbParam.putIfAbsent(AtConstants.atKey, () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data, null);
      //Reset TTB
      updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent(AtConstants.atSign, () => '@alice');
      updateVerbParams.putIfAbsent(AtConstants.atKey, () => 'location');
      updateVerbParams.putIfAbsent(AtConstants.ttb, () => '0');
      updateVerbParams.putIfAbsent(AtConstants.atValue, () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);
      //LLOOKUP Verb - After TTB
      localLookVerbParam.putIfAbsent(AtConstants.atSign, () => '@alice');
      localLookVerbParam.putIfAbsent(AtConstants.atKey, () => 'location');
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

    test('test max key length check', () async {
      var inBoundSessionId = 'testsessionid';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      atConnection.metaData.isAuthenticated = true;
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => '@alice');
      var key = createRandomString(250);
      updateVerbParams.putIfAbsent('atKey', () => key);
      updateVerbParams.putIfAbsent('value', () => 'hyderabad');
      expect(
          () async => await updateVerbHandler.processVerb(
              updateResponse, updateVerbParams, atConnection),
          throwsA(predicate((dynamic e) =>
              e is InvalidAtKeyException &&
              e.message ==
                  'key length ${key.length + '@alice'.length} is greater than max allowed ${AbstractUpdateVerbHandler.maxKeyLengthWithoutCached} chars')));
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
        ..atKey = (AtKey()
          ..key = atKey
          ..sharedBy = alice
          ..sharedWith = bob
          ..metadata = (Metadata()
            ..pubKeyCS = pubKeyCS
            ..sharedKeyEnc = ske
            ..encKeyName = 'some_key'
            ..encAlgo = 'some_algo'
            ..ivNonce = 'some_iv'
            ..skeEncKeyName = skeEncKeyName
            ..skeEncAlgo = skeEncAlgo));
      var updateCommand = updateBuilder.buildCommand().trim();
      expect(
          updateCommand,
          'update'
          ':isEncrypted:false'
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
          updateBuilder.atKey.metadata);

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
          updateBuilder.atKey.metadata);

      // 3. update just some of the metadata and verify
      // Setting few metadata to 'null' to reset them
      updateBuilder.atKey.metadata.skeEncKeyName = 'null';
      updateBuilder.atKey.metadata.skeEncAlgo = 'null';
      updateBuilder.atKey.metadata.sharedKeyEnc = 'null';
      updateBuilder.atKey.metadata.encAlgo = 'WOW/MUCH/ENCRYPTION';
      updateBuilder.atKey.metadata.encKeyName = 'such_secret_key';
      updateBuilder.atKey.metadata.dataSignature =
          'data_signature_to_validate_public_data';
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
      updateBuilder.atKey.metadata = createRandomCommonsMetadata();
      // Setting ttb to null to test existing value is fetched and updated.
      updateBuilder.atKey.metadata.ttb = null;
      updateBuilder.atKey.metadata.dataSignature = null;
      updateBuilder.atKey.metadata.ttr = 10;
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
        ..atKey = (AtKey()
          ..key = atKey
          ..sharedBy = alice
          ..sharedWith = bob
          ..metadata = (Metadata()..ivNonce = 'some_iv'));
      var updateCommand = updateBuilder.buildCommand().trim();
      expect(
          updateCommand,
          'update'
          ':isEncrypted:false'
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
        ..atKey = (AtKey()
          ..key = atKey
          ..sharedBy = alice
          ..sharedWith = bob
          ..metadata = (Metadata()..sharedKeyEnc = 'shared_key_encrypted'))
        ..value = value;

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
      var atConnection = InboundConnectionImpl(mockSocket, null);
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
      var atConnection = InboundConnectionImpl(mockSocket, null);
      await handler.processVerb(response, verbParams, atConnection);
      expect(response.isError, false);
    });
  });

  group('A group of tests when "*" namespace have only read access', () {
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
                  'Connection with enrollment ID $enrollmentId is not authorized to update key: @alice:dummykey.wavi@alice')));
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
                  'Connection with enrollment ID $enrollmentId is not authorized to update key: @alice:dummykey.wavi@alice')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A of tests to verify updating a key when enrollment is pending/revoke/denied state throws exception',
      () {
    Response response = Response();
    late String enrollmentId;
    List operationList = ['pending', 'revoked', 'denied'];

    for (var operation in operationList) {
      test(
          'A test to verify when enrollment is $operation does not update a key',
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
          'approval': {'state': operation}
        };
        var keyName = '$enrollmentId.new.enrollments.__manage@alice';
        await secondaryKeyStore.put(
            keyName, AtData()..data = jsonEncode(enrollJson));
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
                    'Connection with enrollment ID $enrollmentId is not authorized to update key: @alice:dummykey.wavi@alice')));
      });
    }
    tearDown(() async => await verbTestsTearDown());
  });
  group('A group of tests related to access authorization', () {
    Response response = Response();
    late String enrollmentId;
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify update verb is allowed if key is a reserved key',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      String updateCommand = 'update:$bob:shared_key$alice somesharedkey';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.isError, false);
      expect(response.data, isNotNull);
    });
    test(
        'A test to verify update verb is allowed in all namespace when access is *:rw',
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
      expect(response.isError, false);
    });
    test(
        'A test to verify enrollment with no write access to namespace throws exception',
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
      // Update a key with buzz namespace
      String updateCommand = 'update:$alice:phone.buzz$alice 123';
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
                  'Connection with enrollment ID $enrollmentId is not authorized to update key: @alice:phone.buzz@alice')));
    });
    test(
        'A test to verify write access is allowed to a reserved key for an enrollment with a specific namespace access',
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
      String updateCommand = 'update:$bob:shared_key$alice 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
    });
    test(
        'A test to verify write access is allowed to a key without a namespace for an enrollment with * namespace access',
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
      String updateCommand = 'update:$alice:secretdata$alice 123';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
    });
    test(
        'A test to verify write access is denied to a key without a namespace for an enrollment with specific namespace access',
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
      String updateCommand = 'update:$alice:secretdata$alice 123';
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
                  'Connection with enrollment ID $enrollmentId is not authorized to update key: @alice:secretdata@alice')));
    });

    test(
        'A test to verify write access is allowed to a key with a at_contact.buzz namespace for an enrollment with buzz namespace access',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'buzz',
        'deviceName': 'pixel',
        'namespaces': {'buzz': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      String updateCommand =
          'update:atconnections.bob.alice.at_contact.buzz$alice bob';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
    });

    test(
        'A test to verify write access is allowed to a key with a at_contact.buzz namespace for an enrollment with at_contact.buzz namespace access',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'buzz',
        'deviceName': 'pixel',
        'namespaces': {'at_contact.buzz': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      String updateCommand =
          'update:atconnections.bob.alice.at_contact.buzz$alice bob';
      HashMap<String, String?> updateVerbParams =
          getVerbParam(VerbSyntax.update, updateCommand);
      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      await updateVerbHandler.processVerb(
          response, updateVerbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.isError, false);
    });

    test(
        'A test to verify write access is not allowed to a key with only buzz namespace for an enrollment with at_contact.buzz namespace access',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'buzz',
        'deviceName': 'pixel',
        'namespaces': {'at_contact.buzz': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      String updateCommand = 'update:atconnections.bob.alice.buzz$alice bob';
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
                  'Connection with enrollment ID $enrollmentId is not authorized to update key: atconnections.bob.alice.buzz$alice')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to apkam keys expiry', () {
    Response response = Response();
    late String enrollmentId;

    setUp(() async {
      await verbTestsSetUp();
    });

    tearDown(() async => await verbTestsTearDown());

    test('A test to verify update verb fails when apkam keys are expired',
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
      await Future.delayed(Duration(milliseconds: 2));

      String updateCommand = 'update:@alice:phone.wavi@alice 123';

      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      response = await updateVerbHandler.processInternal(
          updateCommand, inboundConnection);
      expect(response.isError, true);
      expect(response.errorCode, 'AT0028');
      expect(response.errorMessage,
          'The enrollment id: $enrollmentId is expired. Closing the connection');
    });
  });
}
