import 'dart:collection';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

void main() async {
  // String thisTestFileName = 'from_verb_test.dart';

  String atSignAlice = '@alice';
  String atSignAliceWithoutTheAtSign = atSignAlice.replaceAll("@", "");

  late final SecondaryKeyStoreManager keyStoreManager;
  var testDataStoragePath = Directory.current.path + '/test/hive/from_verb_test';

  setUpAll(() async {
    // print(thisTestFileName + ' setUpAll starting');

    AtSecondaryServerImpl.getInstance().currentAtSign = atSignAlice;

    var secondaryPersistenceStore =
        SecondaryPersistenceStoreFactory.getInstance().getSecondaryPersistenceStore(AtSecondaryServerImpl.getInstance().currentAtSign)!;

    var commitLogInstance = await AtCommitLogManagerImpl.getInstance().getCommitLog(atSignAlice, commitLogPath: testDataStoragePath);

    secondaryPersistenceStore.getSecondaryKeyStore()!.commitLog = commitLogInstance;

    AtSecondaryServerImpl.getInstance().currentAtSign = atSignAlice;
    AtConfig(AtCommitLogManagerImpl.getInstance().getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign),
        AtSecondaryServerImpl.getInstance().currentAtSign);

    await AtAccessLogManagerImpl.getInstance().getAccessLog(atSignAlice, accessLogPath: testDataStoragePath);

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

  group('A group of from verb regex test', () {
    test('test from correct syntax with @', () {
      var verb = From();
      var command = 'from:' + atSignAlice;
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['atSign'], atSignAlice);
    });

    test('test from correct syntax without @', () {
      var verb = From();
      var command = 'from:' + atSignAliceWithoutTheAtSign;
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['atSign'], atSignAliceWithoutTheAtSign);
    });

    test('test from correct syntax with emoji', () {
      var verb = From();
      var command = 'from:@🦄';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['atSign'], '@🦄');
    });

    test('test from correct syntax with double emoji', () {
      var verb = From();
      var command = 'from:@🦄🦄';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['atSign'], '@🦄🦄');
    });

    test('test from incorrect syntax with emoji', () {
      var verb = From();
      var command = 'from:@@ 🦄';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of from verb accept test', () {
    test('test from accept', () {
      var command = 'from:' + atSignAlice;
      var handler = FromVerbHandler(null);
      expect(handler.accept(command), true);
    });
    test('test from accept invalid keyword', () {
      var command = 'to:' + atSignAlice;
      var handler = FromVerbHandler(null);
      expect(handler.accept(command), false);
    });
    test('test from verb upper case', () {
      var command = 'FROM:' + atSignAlice.toUpperCase();
      command = SecondaryUtil.convertCommand(command);
      var handler = FromVerbHandler(null);
      expect(handler.accept(command), true);
    });
  });
  group('A group of from verb regex -invalid syntax', () {
    test('test from invalid keyword', () {
      var verb = From();
      var command = 'to' + atSignAlice;
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of from verb handler tests', () {
    test('test from verb handler getVerb', () {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      var verb = verbHandler.getVerb();
      expect(verb is From, true);
    });

    test('test from verb handler processverb from atsign contains @', () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = atSignAlice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => atSignAlice);
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data!.startsWith('data:$inBoundSessionId' + atSignAlice), true);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.self, true);
    });

    test('test from verb handler processverb from atsign does not contain @',
        () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = atSignAlice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => atSignAliceWithoutTheAtSign);
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data!.startsWith('data:$inBoundSessionId' + atSignAlice), true);
      expect(response.data!.split(':')[2], isNotNull);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.self, true);
    });

    /*test(
        'test from verb handler processverb from atsign is different from current atsign',
        () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl().currentAtSign = '@tokyo';
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@nairobi');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('proof:$inBoundSessionId@nairobi'), true);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
      expect(connectionMetadata.from, true);
      expect(connectionMetadata.fromAtSign, '@nairobi');
    });*/
  });

  group('A group of from verb handler with configuration test', () {
    test('test from verb handler to allow fromAtSign ', () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
          .getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign);
      await AtConfig(commitLogInstance,
              AtSecondaryServerImpl.getInstance().currentAtSign)
          .addToBlockList({'@bob'});
      AtSecondaryServerImpl.getInstance().currentAtSign = atSignAlice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => atSignAlice);
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data!.startsWith('data:$inBoundSessionId' + atSignAlice), true);
      expect(response.data!.split(':')[2], isNotNull);
      var connectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      expect(connectionMetadata.self, true);
    });

    test('test from verb handler to block fromAtSign ', () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      await AtConfig(
              await AtCommitLogManagerImpl.getInstance().getCommitLog(
                  AtSecondaryServerImpl.getInstance().currentAtSign),
              AtSecondaryServerImpl.getInstance().currentAtSign)
          .addToBlockList({'@bob'});
      AtSecondaryServerImpl.getInstance().currentAtSign = atSignAlice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@bob');
      var response = Response();
      expect(
          () async =>
              await verbHandler.processVerb(response, verbParams, atConnection),
          throwsA(isA<BlockedConnectionException>()));
    });

    /*test('test from verb handler to block fromAtSign first and then allow',
        () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl().currentAtSign = atSignAlice;
      await AtConfig.getInstance().addToBlockList({'@bob'});
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@bob');
      var response = Response();
      expect(
          () async =>
              await verbHandler.processVerb(response, verbParams, atConnection),
          throwsA(isA<BlockedConnectionException>()));
      await AtConfig.getInstance().removeFromBlockList({'@bob'});
      inBoundSessionId = '456';
      atConnection = InboundConnectionImpl(null, inBoundSessionId);
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('proof:$inBoundSessionId@bob'), true);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
      expect(connectionMetadata.from, true);
      expect(connectionMetadata.fromAtSign, '@bob');
    });

    test('test from verb handler to allow fromAtSign first and then block',
        () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl().currentAtSign = atSignAlice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@bob');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('proof:$inBoundSessionId@bob'), true);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
      expect(connectionMetadata.from, true);
      expect(connectionMetadata.fromAtSign, '@bob');
      await AtConfig.getInstance().addToBlockList({'@bob'});
      inBoundSessionId = '456';
      atConnection = InboundConnectionImpl(null, inBoundSessionId);
      expect(
          () async =>
              await verbHandler.processVerb(response, verbParams, atConnection),
          throwsA(isA<BlockedConnectionException>()));
    });*/
  });
}
