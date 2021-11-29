import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

// TODO Refactor. Avoid multiple checks in a single unit test
void main() {
  // String thisTestFileName = 'update_meta_verb_test.dart';

  String atSignKevin = '@kevin';
  String atSignKevinWithoutTheAtSign = atSignKevin.replaceAll("@", "");

  group('A group of update meta verb regex test', () {
    test('test update meta regex', () {
      var verb = UpdateMeta();
      var forAtSignBob = '@bob';
      var command = 'update:meta:' + forAtSignBob + ':location' + atSignKevin + ':ttl:123:ttb:124:ttr:125';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], atSignKevinWithoutTheAtSign);
      expect(paramsMap[FOR_AT_SIGN], forAtSignBob);
      expect(paramsMap[AT_TTL], '123');
      expect(paramsMap[AT_TTB], '124');
      expect(paramsMap[AT_TTR], '125');
    });

    test('test update with ttl with no value', () {
      var verb = UpdateMeta();
      var command = 'update:meta:@bob:location' + atSignKevin + ':ttl:';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test update with no key', () {
      var verb = UpdateMeta();
      var command = 'update:meta:ttl:123';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of test cases with hive', () {
    late final SecondaryKeyStoreManager keyStoreManager;
    var testDataStoragePath = Directory.current.path + '/test/hive/update_meta_verb_test';

    setUpAll(() async {
      // print(thisTestFileName + ' setUpAll starting');

      AtSecondaryServerImpl.getInstance().currentAtSign = atSignKevin;

      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(AtSecondaryServerImpl.getInstance().currentAtSign)!;

      var commitLogInstance = await AtCommitLogManagerImpl.getInstance().getCommitLog(atSignKevin, commitLogPath: testDataStoragePath);

      secondaryPersistenceStore.getSecondaryKeyStore()!.commitLog = commitLogInstance;

      await AtAccessLogManagerImpl.getInstance().getAccessLog(atSignKevin, accessLogPath: testDataStoragePath);

      await secondaryPersistenceStore.getHivePersistenceManager()!.init(testDataStoragePath);

      keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager()!;

      // print(thisTestFileName + ' setUpAll complete');
    });

    tearDownAll(() async {
      // print(thisTestFileName + ' tearDownAll starting');

      // print(thisTestFileName + ' tearDownAll removing test data directory ' + testDataStoragePath);
      await Directory(testDataStoragePath).delete(recursive: true);

      // print(thisTestFileName + ' tearDownAll complete');
    });

    test('test update meta handler processVerb with ttb', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();

      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);

      AtSecondaryServerImpl.getInstance().currentAtSign = atSignKevin;

      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => atSignKevinWithoutTheAtSign);
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
      var updateVerbHandler = UpdateVerbHandler(keyStore);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => '@sitaram');
      updateVerbParams.putIfAbsent('atKey', () => 'phone');
      updateVerbParams.putIfAbsent('value', () => '99899');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);

      //Update Meta
      int ttbMillis = 100;

      var updateMetaVerbHandler =
          UpdateMetaVerbHandler(keyStoreManager.getKeyStore());
      var updateMetaResponse = Response();
      var updateMetaVerbParam = HashMap<String, String>();
      updateMetaVerbParam.putIfAbsent('atSign', () => '@sitaram');
      updateMetaVerbParam.putIfAbsent('atKey', () => 'phone');
      updateMetaVerbParam.putIfAbsent('ttb', () => ttbMillis.toString());
      await updateMetaVerbHandler.processVerb(
          updateMetaResponse, updateMetaVerbParam, atConnection);

      // Look Up verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent('atSign', () => '@sitaram');
      localLookVerbParam.putIfAbsent('atKey', () => 'phone');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      // expect to be null because ttb hasn't been reached
      expect(localLookUpResponse.data, null);

      await Future.delayed(Duration(milliseconds: ttbMillis + 1));
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      // expect actual data because ttb has passed
      expect(localLookUpResponse.data, '99899');
    });

    test('test update meta handler processVerb with ttl', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();

      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);

      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = atSignKevin;
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => atSignKevinWithoutTheAtSign);
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
      var updateVerbHandler = UpdateVerbHandler(keyStore);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => '@sitaram');
      updateVerbParams.putIfAbsent('atKey', () => 'location');
      updateVerbParams.putIfAbsent('value', () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);

      //Update Meta
      int ttlMillis = 100;

      var updateMetaVerbHandler =
          UpdateMetaVerbHandler(keyStoreManager.getKeyStore());
      var updateMetaResponse = Response();
      var updateMetaVerbParam = HashMap<String, String>();
      updateMetaVerbParam.putIfAbsent('atSign', () => '@sitaram');
      updateMetaVerbParam.putIfAbsent('atKey', () => 'location');
      updateMetaVerbParam.putIfAbsent('ttl', () => ttlMillis.toString());
      await updateMetaVerbHandler.processVerb(
          updateMetaResponse, updateMetaVerbParam, atConnection);

      // Look Up verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent('atSign', () => '@sitaram');
      localLookVerbParam.putIfAbsent('atKey', () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      // expect actual data because the ttl hasn't yet passed
      expect(localLookUpResponse.data, 'hyderabad');

      await Future.delayed(Duration(milliseconds: ttlMillis + 1));
      var localLookUpResponse1 = Response();
      await localLookupVerbHandler.processVerb(
          localLookUpResponse1, localLookVerbParam, atConnection);
      // expect null because ttl has passed
      expect(localLookUpResponse1.data, null);
    });
  });
}

