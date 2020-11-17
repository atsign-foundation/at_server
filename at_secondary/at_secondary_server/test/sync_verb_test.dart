import 'dart:collection';
import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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
  setUp(() async => await setUpFunc(storageDir));
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
  });

  group('A group of sync verb handler tests', () {
    test('test sync verb handler one change since last commit', () async {
      var keyStoreManager = SecondaryKeyStoreManager.getInstance();
      keyStoreManager.init();
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
      var keyStoreManager = SecondaryKeyStoreManager.getInstance();
      keyStoreManager.init();
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
      var keyStoreManager = SecondaryKeyStoreManager.getInstance();
      keyStoreManager.init();
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
  });
  tearDown(() async => await tearDownFunc());
}

Future<void> setUpFunc(storageDir) async {
  var isExists = await Directory(storageDir).exists();
  if (!isExists) {
    Directory(storageDir).createSync(recursive: true);
  }
  var persistenceManager = HivePersistenceManager.getInstance();
  await persistenceManager.init('@alice', storageDir);
  await CommitLogKeyStore.getInstance()
      .init('commit_log_' + _getShaForAtsign('@alice'), storageDir);
}

void tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}

String _getShaForAtsign(String atsign) {
  var bytes = utf8.encode(atsign);
  return sha256.convert(bytes).toString();
}
