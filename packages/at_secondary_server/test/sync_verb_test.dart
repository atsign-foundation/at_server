import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();

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
      var command = 'sync:from:5:limit:10';
      var handler = SyncProgressiveVerbHandler(mockKeyStore);
      expect(handler.accept(command), true);
    });
    test('test sync accept invalid keyword', () {
      var command = 'syncing:1';
      var handler = SyncProgressiveVerbHandler(mockKeyStore);
      expect(handler.accept(command), false);
    });
    test('test sync verb upper case', () {
      var command = 'SYNC:from:5:limit:10';
      command = SecondaryUtil.convertCommand(command);
      var handler = SyncProgressiveVerbHandler(mockKeyStore);
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

  group('storage based sync tests', () {
    var storageDir = '${Directory.current.path}/test/hive';
    late SecondaryKeyStoreManager keyStoreManager;
    SyncProgressiveVerbHandler verbHandler;
    setUp(() async => keyStoreManager = await setUpFunc(storageDir));

    test('A test to verify sync metadata is populated correctly', () async {
      // Add data to commit log
      var atCommitLog =
          await AtCommitLogManagerImpl.getInstance().getCommitLog('@alice');
      await atCommitLog?.commit('phone.wavi@alice', CommitOp.UPDATE);
      //Add data to keystore
      var secondaryKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@alice');
      await secondaryKeyStore?.getSecondaryKeyStore()?.put(
          'phone.wavi@alice',
          AtData()
            ..data = '+9189877783232'
            ..metaData = (AtMetaData()
              ..ttl = 10000
              ..ttb = 1000
              ..ttr = 100
              ..isBinary = false
              ..encoding = 'base64'));

      verbHandler = SyncProgressiveVerbHandler(keyStoreManager.getKeyStore());
      var response = Response();
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '0');
      verbParams.putIfAbsent('limit', () => '10');
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      await verbHandler.processVerb(response, verbParams, atConnection);

      Map syncResponseMap = (jsonDecode(response.data!)).first;
      expect(syncResponseMap['atKey'], 'phone.wavi@alice');
      expect(syncResponseMap['value'], '+9189877783232');
      expect(syncResponseMap['commitId'], 1);
      expect(syncResponseMap['operation'], '*');
      expect(syncResponseMap['metadata']['ttl'], '10000');
      expect(syncResponseMap['metadata']['ttb'], '1000');
      expect(syncResponseMap['metadata']['ttr'], '100');
      expect(syncResponseMap['metadata']['isBinary'], 'false');
      expect(syncResponseMap['metadata']['encoding'], 'base64');
    });

    when(() => mockKeyStore.isKeyExists(any())).thenReturn(true);
    when(() => mockKeyStore.get(any()))
        .thenAnswer((invocation) => Future(() => AtData()));

    test('test to ensure at least one entry is synced always', () async {
      verbHandler = SyncProgressiveVerbHandler(mockKeyStore);
      AtCommitLog atCommitLog = (await (AtCommitLogManagerImpl.getInstance()
          .getCommitLog('@alice')))!;

      // Creating dummy commit entries
      await atCommitLog.commit('test_key_alpha@alice', CommitOp.UPDATE_ALL);
      await atCommitLog.commit('test_key2_beta@alice', CommitOp.UPDATE);
      // ensure commitLog is not empty
      assert(atCommitLog.entriesCount() > 0);

      List<KeyStoreEntry> syncResponse = [];
      await verbHandler.prepareResponse(
          0, syncResponse, atCommitLog.getEntries(0));
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key_alpha@alice');
    });

    test(
        'overflowing entry not added to syncResponse when syncResponse not empty',
        () async {
      verbHandler = SyncProgressiveVerbHandler(mockKeyStore);
      AtCommitLog atCommitLog = (await (AtCommitLogManagerImpl.getInstance()
          .getCommitLog('@alice')))!;

      List<KeyStoreEntry> syncResponse = [];

      // Creating dummy commit entries
      await atCommitLog.commit('test_key_alpha@alice', CommitOp.UPDATE_ALL);
      await atCommitLog.commit('test_key2_beta@alice', CommitOp.UPDATE);
      // Ensure commitLog is not empty
      expect(atCommitLog.entriesCount(), greaterThan(0));

      var entry = KeyStoreEntry()
        ..key = 'dummy'
        ..commitId = 11
        ..operation = CommitOp.UPDATE_ALL
        ..value = 'whatever';
      // Inserting an element into syncResponse, so that now it isn't empty
      syncResponse.add(entry);

      // Since syncResponse already has an entry, and the 'capacity' is 0, then the next entry
      // should not be added to the syncResponse
      await verbHandler.prepareResponse(
          0, syncResponse, atCommitLog.getEntries(0));
      expect(syncResponse, [entry]);

      syncResponse.clear();
      await verbHandler.prepareResponse(
          0, syncResponse, atCommitLog.getEntries(0));
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key_alpha@alice');

      syncResponse.clear();
      await verbHandler.prepareResponse(
          0, syncResponse, atCommitLog.getEntries(1));
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key2_beta@alice');
    });

    test('test to ensure all entries are synced if buffer does not overflow',
        () async {
      verbHandler = SyncProgressiveVerbHandler(mockKeyStore);
      AtCommitLog atCommitLog = (await (AtCommitLogManagerImpl.getInstance()
          .getCommitLog('@alice')))!;

      // Creating dummy commit entries
      await atCommitLog.commit('test_key_alpha@alice', CommitOp.UPDATE_ALL);
      await atCommitLog.commit('test_key2_beta@alice', CommitOp.UPDATE);
      await atCommitLog.commit('abcd@alice', CommitOp.UPDATE_ALL);
      await atCommitLog.commit(
          'another_random_key@alice', CommitOp.UPDATE_META);

      // ensure commitLog is not empty
      var commitLogLength = atCommitLog.entriesCount();
      expect(commitLogLength, 4);

      List<KeyStoreEntry> syncResponse = [];
      var entry = KeyStoreEntry()
        ..key = 'dummy'
        ..commitId = 11
        ..operation = CommitOp.UPDATE_ALL
        ..value = 'whatever';
      // Inserting an element into syncResponse, so that now it isn't empty
      syncResponse.add(entry);

      await verbHandler.prepareResponse(
          10 * 1024 * 1024, syncResponse, atCommitLog.getEntries(0));

      // Expecting that all the entries in the commitLog have been
      // added to syncResponse
      expect(syncResponse.length, commitLogLength + 1);
      expect(syncResponse[0], entry);
      expect(syncResponse[1].key, 'test_key_alpha@alice');
      expect(syncResponse[2].key, 'test_key2_beta@alice');
      expect(syncResponse[3].key, 'abcd@alice');
      expect(syncResponse[4].key, 'another_random_key@alice');
    });

    test(
        'ensure only one overflowing entry is added to syncResponse when commitLog has two large entries',
        () async {
      verbHandler = SyncProgressiveVerbHandler(mockKeyStore);
      AtCommitLog atCommitLog = (await (AtCommitLogManagerImpl.getInstance()
          .getCommitLog('@alice')))!;

      // Creating dummy commit entries
      await atCommitLog.commit('test_key1@alice', CommitOp.UPDATE_ALL);
      await atCommitLog.commit('test_key2@alice', CommitOp.UPDATE);
      // ensure commitLog is not empty
      assert(atCommitLog.entriesCount() == 2);

      List<KeyStoreEntry> syncResponse = [];
      await verbHandler.prepareResponse(
          0, syncResponse, atCommitLog.getEntries(0));
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key1@alice');

      syncResponse.clear();
      await verbHandler.prepareResponse(
          0, syncResponse, atCommitLog.getEntries(1));
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key2@alice');

      // test with empty iterator
      syncResponse.clear();
      await verbHandler.prepareResponse(
          10 * 1024 * 1024, syncResponse, atCommitLog.getEntries(2));
      expect(syncResponse.length, 0);
    });

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
          AtSecondaryServerImpl.getInstance().currentAtSign)!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice', commitLogPath: storageDir);
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
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
