import 'dart:collection';
import 'dart:convert';

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
import 'package:at_utils/at_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  AtSignLogger.root_level = 'FINEST';

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group('A group of update meta verb regex test', () {
    test('test update meta regex', () {
      var verb = UpdateMeta();
      var command = 'update:meta:@bob:location@kevin:ttl:123:ttb:124:ttr:125';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], 'kevin');
      expect(paramsMap[FOR_AT_SIGN], 'bob');
      expect(paramsMap[AT_TTL], '123');
      expect(paramsMap[AT_TTB], '124');
      expect(paramsMap[AT_TTR], '125');
    });

    test('test update with ttl with no value', () {
      var verb = UpdateMeta();
      var command = 'update:meta:@bob:location@kevin:ttl:';
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
    test('test update meta handler processVerb with ttb', () async {
      //Update Verb
      var updateVerbHandler = UpdateVerbHandler(
          secondaryKeyStore, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => alice);
      updateVerbParams.putIfAbsent('forAtSign', () => bob);
      updateVerbParams.putIfAbsent('atKey', () => 'phone');
      updateVerbParams.putIfAbsent('value', () => '99899');

      inboundConnection.metadata.isAuthenticated = true;
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, inboundConnection);

      int ttb = 100; // ttb, in milliseconds
      //Update Meta
      var updateMetaVerbHandler = UpdateMetaVerbHandler(
          secondaryKeyStore, notificationManager);
      var updateMetaResponse = Response();
      var updateMetaVerbParam = HashMap<String, String>();
      updateMetaVerbParam.putIfAbsent('atSign', () => alice);
      updateVerbParams.putIfAbsent('forAtSign', () => bob);
      updateMetaVerbParam.putIfAbsent('atKey', () => 'phone');
      updateMetaVerbParam.putIfAbsent('ttb', () => ttb.toString());
      await updateMetaVerbHandler.processVerb(
          updateMetaResponse, updateMetaVerbParam, inboundConnection);

      // Look Up verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent('atSign', () => alice);
      localLookVerbParam.putIfAbsent('forAtSign', () => bob);
      localLookVerbParam.putIfAbsent('atKey', () => 'phone');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, inboundConnection);
      expect(localLookUpResponse.data,
          null); // should be null, as we have not yet reached ttb

      await Future.delayed(Duration(milliseconds: ttb));
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, inboundConnection);
      expect(localLookUpResponse.data, '99899');
    });

    test('test update meta handler processVerb with ttl', () async {
      SecondaryKeyStore keyStore = secondaryKeyStore;
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(secondaryKeyStore);
      AtSecondaryServerImpl.getInstance().currentAtSign = '@kevin';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'kevin');
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
      var updateVerbHandler =
          UpdateVerbHandler(keyStore, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => '@kevin');
      updateVerbParams.putIfAbsent('atKey', () => 'location');
      updateVerbParams.putIfAbsent('value', () => 'hyderabad');
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, atConnection);

      int ttl = 100; // in milliseconds

      //Update Meta
      var updateMetaVerbHandler = UpdateMetaVerbHandler(
          secondaryKeyStore, notificationManager);
      var updateMetaResponse = Response();
      var updateMetaVerbParam = HashMap<String, String>();
      updateMetaVerbParam.putIfAbsent('atSign', () => '@kevin');
      updateMetaVerbParam.putIfAbsent('atKey', () => 'location');
      updateMetaVerbParam.putIfAbsent('ttl', () => ttl.toString());
      await updateMetaVerbHandler.processVerb(
          updateMetaResponse, updateMetaVerbParam, atConnection);

      // Look Up verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(keyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent('atSign', () => '@kevin');
      localLookVerbParam.putIfAbsent('atKey', () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, atConnection);
      expect(localLookUpResponse.data,
          'hyderabad'); // ttl not yet reached, value will be live

      await Future.delayed(Duration(milliseconds: ttl));
      var localLookUpResponse1 = Response();
      await localLookupVerbHandler.processVerb(
          localLookUpResponse1, localLookVerbParam, atConnection);
      expect(localLookUpResponse1.data,
          null); // ttl has passed, value should no longer be live
    });
  });
}
