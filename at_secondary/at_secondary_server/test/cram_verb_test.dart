import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = Directory.current.path + '/test/hive';
  late var keyStoreManager;
  setUp(() async => keyStoreManager = await setUpFunc(storageDir));
  group('A group of cram verb regex test', () {
    test('test from correct syntax with digest', () {
      var verb = Cram();
      var command = 'cram:abc123';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['digest'], 'abc123');
    });

    test('test cram accept', () {
      var command = 'cram:abc123';
      var handler = CramVerbHandler(null);
      expect(handler.accept(command), true);
    });
    test('test from accept invalid keyword', () {
      var command = 'cramer:';
      var handler = CramVerbHandler(null);
      expect(handler.accept(command), false);
    });
    test('test cram  without digest', () {
      var verb = Cram();
      var command = 'cram:';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of cram verb handler tests', () {
    test('test cram verb handler getVerb', () {
      var verbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var verb = verbHandler.getVerb();
      expect(verb is Cram, true);
    });

    test('test cram verb handler processVerb auth fail', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
      'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
      var atConnection = DummyInboundConnection.getInstance();
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}randomfromresponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var verbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var cramResponse = Response();
      expect(
              () async => await verbHandler.processVerb(
              cramResponse, cramVerbParams, atConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
      expect(atConnection.getMetaData().isAuthenticated, false);
    });

    test('test cram verb handler processVerb auth success', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
      var atConnection = DummyInboundConnection.getInstance();
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst('data:', '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var verbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var cramResponse = Response();
      await verbHandler.processVerb(cramResponse, cramVerbParams, atConnection);
      expect(atConnection.getMetaData().isAuthenticated, true);
      expect(cramResponse.data, 'success');
    });

    test('test cram verb handler processVerb no secret in keystore', () async {
      var fromVerbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@test_user_1';
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = DummyInboundConnection.getInstance();
      atConnection.getMetaData().sessionID = inBoundSessionId;
      atConnection.getMetaData().isAuthenticated = false;
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var cramVerbParams = HashMap<String, String>();
      var combo = 'randomstring';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var verbHandler = CramVerbHandler(keyStoreManager.getKeyStore());
      var cramResponse = Response();
      expect(
          () async => await verbHandler.processVerb(
              cramResponse, cramVerbParams, atConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
      expect(atConnection.getMetaData().isAuthenticated, false);
    });
  });
  tearDown(() async => await tearDownFunc());
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@test_user_1')!;
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@test_user_1', commitLogPath: storageDir);
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init('@test_user_1', storageDir);
  await persistenceManager.openVault('@test_user_1');
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  await AtAccessLogManagerImpl.getInstance()
      .getAccessLog('@test_user_1', accessLogPath: storageDir);
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
