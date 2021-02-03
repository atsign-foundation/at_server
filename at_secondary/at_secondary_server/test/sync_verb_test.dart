import 'dart:collection';
import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/sync_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

void main() async {
  var storageDir = Directory.current.path + '/test/hive';
  var keyStoreManager;

  group('A group of sync verb regex test', () {
    test('test sync correct syntax', () {
      var verb = Sync();
      var command = 'sync:5';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['from_commit_seq'], '5');
    });

    test('test sync incorrect no sequence number', () {
      var verb = Sync();
      var command = 'sync:';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test sync incorrect multiple sequence number', () {
      var verb = Sync();
      var command = 'sync:5 6 7';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test sync incorrect sequence number with alphabet', () {
      var verb = Sync();
      var command = 'sync:5a';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of sync verb accept test', () {
    test('test sync accept', () {
      var command = 'sync:5';
      var handler = SyncVerbHandler(null);
      expect(handler.accept(command), true);
    });
    test('test sync accept invalid keyword', () {
      var command = 'syncing:1';
      var handler = SyncVerbHandler(null);
      expect(handler.accept(command), false);
    });
    test('test sync verb upper case', () {
      var command = 'SYNC:5';
      command = SecondaryUtil.convertCommand(command);
      var handler = SyncVerbHandler(null);
      expect(handler.accept(command), true);
    });
    test('test sync verb with regex', () {
      var verb = Sync();
      var command = 'sync:-1:me';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['from_commit_seq'], '-1');
      expect(paramsMap['regex'], 'me');
    });
  });

  group('A group of sync verb handler tests', () {
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));
    test('test sync verb handler one change since last commit', () async {
      SecondaryKeyStore keyStore = keyStoreManager.getKeyStore();
      var atData_1 = AtData();
      atData_1.data = 'newyork';
      await keyStore.put('location@alice', atData_1);
      var atData_2 = AtData();
      atData_2.data = '1234';
      await keyStore.put('phone@alice', atData_2);
      var atData_3 = AtData();
      atData_3.data = 'wonderland';
      await keyStore.put('lastname@alice', atData_3);
      var verbHandler = SyncVerbHandler(keyStore);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('from_commit_seq', () => '1');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, null);
      expect(response.data, isNotNull);
      var json = jsonDecode(response.data);
      expect(json.length, 1);
      expect(json[0]['atKey'], 'lastname@alice');
      expect(json[0]['commitId'], 2);
    });
    test('test sync verb handler multiple change since last commit', () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign);
      var keyStoreManager =
          secondaryPersistenceStore.getSecondaryKeyStoreManager();
      var keyStore = keyStoreManager.getKeyStore();
      var atData_1 = AtData();
      atData_1.data = 'newyork';
      await keyStore.put('location@alice', atData_1);
      var atData_2 = AtData();
      atData_2.data = '1234';
      await keyStore.put('phone@alice', atData_2);
      var atData_3 = AtData();
      atData_3.data = 'wonderland';
      await keyStore.put('lastname@alice', atData_3);
      var verbHandler = SyncVerbHandler(keyStore);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('from_commit_seq', () => '0');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, null);
      expect(response.data, isNotNull);
      var json = jsonDecode(response.data);
      expect(json.length, 2);
      expect(json[0]['atKey'], 'phone@alice');
      expect(json[0]['commitId'], 1);
      expect(json[1]['atKey'], 'lastname@alice');
      expect(json[1]['commitId'], 2);
    });

    test('test sync verb handler no change since last commit', () async {
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var secondaryPersistenceStore =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(
                  AtSecondaryServerImpl.getInstance().currentAtSign);
      var keyStoreManager =
          secondaryPersistenceStore.getSecondaryKeyStoreManager();
      var keyStore = keyStoreManager.getKeyStore();
      var atData_1 = AtData();
      atData_1.data = 'newyork';
      await keyStore.put('location@alice', atData_1);
      var atData_2 = AtData();
      atData_2.data = '1234';
      await keyStore.put('phone@alice', atData_2);
      var atData_3 = AtData();
      atData_3.data = 'wonderland';
      await keyStore.put('lastname@alice', atData_3);
      var verbHandler = SyncVerbHandler(keyStore);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('from_commit_seq', () => '2');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, null);
      expect(response.data, isNull);
    });

    // test('test sync verb handler with regex', () async {
    //   var keyStoreManager = SecondaryKeyStoreManager.getInstance();
    //   keyStoreManager.init();
    //   var keyStore = keyStoreManager.getKeyStore();
    //   var atData_1 = AtData();
    //   atData_1.data = 'newyork';
    //   await keyStore.put('location.me@alice', atData_1);
    //   var atData_2 = AtData();
    //   atData_2.data = '1234';
    //   await keyStore.put('phone@alice', atData_2);
    //   var atData_3 = AtData();
    //   atData_3.data = 'wonderland';
    //   await keyStore.put('lastname@alice', atData_3);
    //   var verbHandler = SyncVerbHandler(keyStore);
    //   var verbParams = HashMap<String, String>();
    //   verbParams.putIfAbsent('from_commit_seq', () => '-1');
    //   verbParams.putIfAbsent('regex', () => '\\.me');
    //   var response = Response();
    //   await verbHandler.processVerb(response, verbParams, null);
    //   var responseJSON = jsonDecode(response.data);
    //   expect(responseJSON[0]['atKey'], 'location.me@alice');
    //   expect(responseJSON[0]['operation'], '+');
    // });
    tearDown(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  var isExists = await Directory(storageDir).exists();
  if (!isExists) {
    Directory(storageDir).createSync(recursive: true);
  }
  AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign);
  var persistenceManager = secondaryPersistenceStore.getPersistenceManager();
  await persistenceManager.init('@alice', storagePath: storageDir);
  await persistenceManager.openVault('@alice');
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice', commitLogPath: storageDir);
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager.keyStore = hiveKeyStore;
  return keyStoreManager;
}

void tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
  AtCommitLogManagerImpl.getInstance().clear();
}
