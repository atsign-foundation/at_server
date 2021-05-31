import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/sync_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() async {
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
  tearDown(() async => await tearDownFunc());
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
  await persistenceManager.init('@alice', storageDir);
  if (persistenceManager is HivePersistenceManager) {
    await persistenceManager.openVault('@alice');
  }
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getHiveCommitLog('@alice', commitLogPath: storageDir);
  var hiveKeyStore;
  hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore();
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager = secondaryPersistenceStore.getSecondaryKeyStoreManager();
  keyStoreManager.keyStore = hiveKeyStore;
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
