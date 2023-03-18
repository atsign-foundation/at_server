import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
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
          secondaryKeyStore, statsNotificationService, notificationManager);
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
      var upMetaHandler = UpdateMetaVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      var upMetaR = Response();
      var upMetaParams = HashMap<String, String>();
      upMetaParams.putIfAbsent('atSign', () => alice);
      upMetaParams.putIfAbsent('forAtSign', () => bob);
      upMetaParams.putIfAbsent('atKey', () => 'phone');
      upMetaParams.putIfAbsent('ttb', () => ttb.toString());
      await upMetaHandler.processVerb(
          upMetaR, upMetaParams, inboundConnection);

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
      //Update Verb
      var updateVerbHandler =
          UpdateVerbHandler(secondaryKeyStore, statsNotificationService, notificationManager);
      var updateResponse = Response();
      var updateVerbParams = HashMap<String, String>();
      updateVerbParams.putIfAbsent('atSign', () => alice);
      updateVerbParams.putIfAbsent('forAtSign', () => bob);
      updateVerbParams.putIfAbsent('atKey', () => 'location');
      updateVerbParams.putIfAbsent('value', () => 'hyderabad');
      inboundConnection.metadata.isAuthenticated = true;
      await updateVerbHandler.processVerb(
          updateResponse, updateVerbParams, inboundConnection);

      int ttl = 100; // in milliseconds

      //Update Meta
      var updateMetaVerbHandler = UpdateMetaVerbHandler(
          secondaryKeyStore, statsNotificationService, notificationManager);
      var updateMetaResponse = Response();
      var upMetaParams = HashMap<String, String>();
      upMetaParams.putIfAbsent('atSign', () => alice);
      upMetaParams.putIfAbsent('forAtSign', () => bob);
      upMetaParams.putIfAbsent('atKey', () => 'location');
      upMetaParams.putIfAbsent('ttl', () => ttl.toString());
      inboundConnection.metadata.isAuthenticated = true;
      await updateMetaVerbHandler.processVerb(
          updateMetaResponse, upMetaParams, inboundConnection);

      // Look Up verb
      var localLookUpResponse = Response();
      var localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
      var localLookVerbParam = HashMap<String, String>();
      localLookVerbParam.putIfAbsent('atSign', () => alice);
      localLookVerbParam.putIfAbsent('forAtSign', () => bob);
      localLookVerbParam.putIfAbsent('atKey', () => 'location');
      await localLookupVerbHandler.processVerb(
          localLookUpResponse, localLookVerbParam, inboundConnection);
      expect(localLookUpResponse.data,
          'hyderabad'); // ttl not yet reached, value will be live

      await Future.delayed(Duration(milliseconds: ttl));
      var localLookUpResponse1 = Response();
      await localLookupVerbHandler.processVerb(
          localLookUpResponse1, localLookVerbParam, inboundConnection);
      expect(localLookUpResponse1.data,
          null); // ttl has passed, value should no longer be live
    });
  });
}
