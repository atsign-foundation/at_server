import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';

void main() async {
  var storageDir = Directory.current.path + '/test/hive';
  var keyStoreManager;
  setUp(() async => keyStoreManager = await setUpFunc(storageDir));
  group('A group of from verb regex test', () {
    test('test from correct syntax with @', () {
      var verb = From();
      var command = 'from:@alice';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['atSign'], '@alice');
    });

    test('test from correct syntax without @', () {
      var verb = From();
      var command = 'from:alice';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['atSign'], 'alice');
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
          throwsA(predicate((e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of from verb accept test', () {
    test('test from accept', () {
      var command = 'from:@alice';
      var handler = FromVerbHandler(null);
      expect(handler.accept(command), true);
    });
    test('test from accept invalid keyword', () {
      var command = 'to:@alice';
      var handler = FromVerbHandler(null);
      expect(handler.accept(command), false);
    });
    test('test from verb upper case', () {
      var command = 'FROM:@ALICE';
      command = SecondaryUtil.convertCommand(command);
      var handler = FromVerbHandler(null);
      expect(handler.accept(command), true);
    });
  });
  group('A group of from verb regex -invalid syntax', () {
    test('test from invalid keyword', () {
      var verb = From();
      var command = 'to:@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((e) =>
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
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@alice');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('data:$inBoundSessionId@alice'), true);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
      expect(connectionMetadata.self, true);
    });

    test('test from verb handler processverb from atsign does not contain @',
        () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => 'alice');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('data:$inBoundSessionId@alice'), true);
      expect(response.data.split(':')[2], isNotNull);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
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
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
      await AtConfig.getInstance().addToBlockList({'@bob'});
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@alice');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('data:$inBoundSessionId@alice'), true);
      expect(response.data.split(':')[2], isNotNull);
      InboundConnectionMetadata connectionMetadata = atConnection.getMetaData();
      expect(connectionMetadata.self, true);
    });

    test('test from verb handler to block fromAtSign ', () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice';
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
    });

    /*test('test from verb handler to block fromAtSign first and then allow',
        () async {
      var verbHandler = FromVerbHandler(keyStoreManager.getKeyStore());
      AtSecondaryServerImpl().currentAtSign = '@alice';
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
      AtSecondaryServerImpl().currentAtSign = '@alice';
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

  tearDown(() async => tearDownFunc());

  if (Directory(storageDir).existsSync()) {
    Directory(storageDir).deleteSync(recursive: true);
  }
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir) async {
  await CommitLogKeyStore.getInstance()
      .init('commit_log_' + _getShaForAtsign('@alice'), storageDir);
  var persistenceManager = HivePersistenceManager.getInstance();
  await persistenceManager.init('@alice', storageDir);
  await persistenceManager.openVault('@alice');
//  persistenceManager.scheduleKeyExpireTask(1); //commented this line for coverage test
  var keyStoreManager = SecondaryKeyStoreManager.getInstance();
  keyStoreManager.init();
  await AccessLogKeyStore.getInstance()
      .init('access_log_' + _getShaForAtsign('@alice'), storageDir);
  return keyStoreManager;
}

void tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    await Directory('test/hive').deleteSync(recursive: true);
  }
}

String _getShaForAtsign(String atsign) {
  var bytes = utf8.encode(atsign);
  return sha256.convert(bytes).toString();
}
