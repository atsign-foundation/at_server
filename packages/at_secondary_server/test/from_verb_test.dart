import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() async {
  late AtKeyValueStore<String, AtData, AtMetaData?> mockKeyStore;
  late FakeSocket mockSocket;

  verbTestsSetUpLogging();

  var storageDir = '${Directory.current.path}/test/hive';
  late AtKeyValueStore<String, AtData, AtMetaData?> keyValueStore;
  setUp(() async {
    mockKeyStore = MockAtKeyValueStore();
    mockSocket = FakeSocket();
    keyValueStore = await setUpFunc(storageDir);
  });
  group('A group of from verb regex test', () {
    test('test from correct syntax with @', () {
      var verb = From();
      var command = 'from:$alice';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap['atSign'], alice);
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
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of from verb accept test', () {
    test('test from accept', () {
      var command = 'from:$alice';
      var handler = FromVerbHandler(mockKeyStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      expect(handler.accept(command), true);
    });
    test('test from accept invalid keyword', () {
      var command = 'to:$alice';
      var handler = FromVerbHandler(mockKeyStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      expect(handler.accept(command), false);
    });
    test('test from verb upper case', () {
      var command = 'FROM:$alice';
      command = SecondaryUtil.convertCommand(command);
      var handler = FromVerbHandler(mockKeyStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      expect(handler.accept(command), true);
    });
  });
  group('A group of from verb regex -invalid syntax', () {
    test('test from invalid keyword', () {
      var verb = From();
      var command = 'to:$alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });

  group('A group of from verb handler tests', () {
    test('test from verb handler getVerb', () {
      var verbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      var verb = verbHandler.getVerb();
      expect(verb is From, true);
    });

    test('test from verb handler from atsign contains @', () async {
      var verbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => alice);
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data!.startsWith('data:$inBoundSessionId$alice'), true);
      var connectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      expect(connectionMetadata.self, true);
    });

    test('test from verb handler from atsign does not contain @', () async {
      var verbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => 'alice');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data!.startsWith('data:$inBoundSessionId$alice'), true);
      expect(response.data!.split(':')[2], isNotNull);
      var connectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      expect(connectionMetadata.self, true);
    });

    /*test(
        'test from verb handler - from atsign is different from current atsign',
        () async {
      var verbHandler = FromVerbHandler(keyValueStore, commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl().currentAtSign = '@tokyo';
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@nairobi');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('proof:$inBoundSessionId@nairobi'), true);
      InboundConnectionMetadata connectionMetadata = atConnection.metaData;
      expect(connectionMetadata.from, true);
      expect(connectionMetadata.fromAtSign, '@nairobi');
    });*/
  });

  group('A from verb on a connection that has authenticated', () {
    late FromVerbHandler verbHandler;
    late _ClosableConnection connection;

    setUp(() {
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      verbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      connection = _ClosableConnection();
    });

    test('A connection stays bound to the atSign it proved', () async {
      connection.metaData
        ..from = true
        ..fromAtSign = '@chuck'.toAtsign()
        ..isPolAuthenticated = true;

      await verbHandler.process('from:@carol', connection);

      expect(connection.lastWrittenData, startsWith('error:AT0009'));
      expect(connection.closed, isTrue);
      expect(connection.metaData.fromAtSign, '@chuck'.toAtsign());
      expect(connection.metaData.isPolAuthenticated, isTrue);
    });

    test('An owner connection stays bound to its atSign', () async {
      connection.metaData
        ..self = true
        ..isAuthenticated = true;

      await verbHandler.process('from:@chuck', connection);

      expect(connection.lastWrittenData, startsWith('error:AT0009'));
      expect(connection.closed, isTrue);
      expect(connection.metaData.from, isFalse);
      expect(connection.metaData.fromAtSign, isNull);
    });

    test('a from: run by another verb, as batch runs it, is refused', () async {
      connection.metaData.isAuthenticated = true;
      final verbParams = HashMap<String, String>()
        ..[AtConstants.atSign] = '@chuck';

      await expectLater(
          verbHandler.processVerb(Response(), verbParams, connection),
          throwsA(isA<UnAuthorizedException>()));
      expect(connection.metaData.from, isFalse);
      expect(connection.metaData.fromAtSign, isNull);
    });

    group(
        'A from: naming the atSign the connection proved is answered as before',
        () {
      test('on an owner connection', () async {
        connection.metaData
          ..self = true
          ..isAuthenticated = true;

        await verbHandler.process('from:@alice', connection);

        expect(connection.lastWrittenData, startsWith('data:'));
        expect(connection.closed, isFalse);
        expect(connection.metaData.isAuthenticated, isTrue);
      });

      test('on a pol connection', () async {
        connection.metaData
          ..from = true
          ..fromAtSign = '@chuck'.toAtsign()
          ..isPolAuthenticated = true;

        try {
          await verbHandler.process('from:@chuck', connection);
        } on SecondaryNotFoundException {
          // NOTE with clientCertificateRequired, the certificate check that
          // follows has no directory entry for @chuck in this harness.
        }

        expect(connection.lastWrittenData ?? '',
            isNot(startsWith('error:AT0009')));
        expect(connection.closed, isFalse);
        expect(connection.metaData.fromAtSign, '@chuck'.toAtsign());
        expect(connection.metaData.isPolAuthenticated, isTrue);
      });
    });

    test('a from: before authentication may be sent again', () async {
      await verbHandler.process('from:@alice', connection);
      await verbHandler.process('from:@alice', connection);

      expect(connection.lastWrittenData, startsWith('data:'));
      expect(connection.closed, isFalse);
      expect(connection.metaData.self, isTrue);
    });
  });

  group('A from verb clientConfig', () {
    /// The metadata of a connection after `from:` with [clientConfig].
    Future<InboundConnectionMetadata> metadataAfter(
        Map<String, Object?> clientConfig) async {
      final verbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      final atConnection = InboundConnectionImpl(mockSocket, '123');
      final verbParams = HashMap<String, String>()
        ..[AtConstants.atSign] = alice.toString()
        ..[AtConstants.clientConfig] = jsonEncode(clientConfig);
      await verbHandler.processVerb(Response(), verbParams, atConnection);
      return atConnection.metaData as InboundConnectionMetadata;
    }

    test('is kept as sent when it is well formed', () async {
      final metadata = await metadataAfter({
        AtConstants.version: '3.0.38',
        AtConstants.clientId: '0f3e5a2c-1b7d-4c8e-9f60-2a4b6c8d0e1f',
        AtConstants.appName: 'wavi',
        AtConstants.appVersion: '1.2.3',
        AtConstants.platform: 'macos',
      });
      expect(metadata.clientVersion, '3.0.38');
      expect(metadata.clientId, '0f3e5a2c-1b7d-4c8e-9f60-2a4b6c8d0e1f');
      expect(metadata.appName, 'wavi');
      expect(metadata.appVersion, '1.2.3');
      expect(metadata.platform, 'macos');
    });

    test('is escaped before it goes into the log prefix', () async {
      // These fields prefix every log line for the connection.
      final metadata = await metadataAfter({
        AtConstants.clientId: 'x\nyy',
        AtConstants.appName: 'a\rb',
        AtConstants.appVersion: '\x1b[2J',
        AtConstants.platform: 'p\u0085',
      });
      final String prefix = AtSignLogger('test')
          .getAtConnectionLogMessage(metadata, 'RCVD: noop:0');
      expect(prefix, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
      expect(metadata.clientId, r'x\nyy');
      expect(metadata.appName, r'a\rb');
      expect(metadata.appVersion, r'\x1b[2J');
      expect(metadata.platform, r'p\x85');
    });

    test('is cut to a bounded length', () async {
      final metadata = await metadataAfter({AtConstants.appName: 'a' * 5000});
      expect(metadata.appName, '${'a' * 64} [truncated, 4936 more chars]');
    });

    test('a field that is not a string is ignored, not a TypeError', () async {
      final metadata = await metadataAfter({
        AtConstants.version: 3,
        AtConstants.clientId: 42,
        AtConstants.appName: ['wavi'],
        AtConstants.appVersion: {'major': 1},
        AtConstants.platform: true,
      });
      expect(metadata.clientVersion,
          AtConnectionMetaData.clientVersionNotAvailable);
      expect(metadata.clientId, isNull);
      expect(metadata.appName, isNull);
      expect(metadata.appVersion, isNull);
      expect(metadata.platform, isNull);
    });

    test('a version that does not parse is ignored', () async {
      // GlobalExceptionHandler parses it to format an error, and would throw.
      final metadata =
          await metadataAfter({AtConstants.version: 'not-a-version'});
      expect(metadata.clientVersion,
          AtConnectionMetaData.clientVersionNotAvailable);
    });

    test('without a version leaves the version not available', () async {
      final metadata = await metadataAfter({AtConstants.clientId: 'c'});
      expect(metadata.clientVersion,
          AtConnectionMetaData.clientVersionNotAvailable);
      expect(metadata.clientId, 'c');
    });
  });

  group('A group of from verb handler with configuration test', () {
    test('test from verb handler to allow fromAtSign ', () async {
      var verbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      await AtConfig(
              keyValueStore, AtSecondaryServerImpl.getInstance().currentAtSign)
          .addToBlockList({'@bob'});
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => alice);
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data!.startsWith('data:$inBoundSessionId$alice'), true);
      expect(response.data!.split(':')[2], isNotNull);
      var connectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      expect(connectionMetadata.self, true);
    });

    test('test from verb handler to block fromAtSign ', () async {
      var verbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      await AtConfig(
              keyValueStore, AtSecondaryServerImpl.getInstance().currentAtSign)
          .addToBlockList({'@bob'});
      AtSecondaryServerImpl.getInstance().currentAtSign = alice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
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
      var verbHandler = FromVerbHandler(keyValueStore, commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl().currentAtSign = alice;
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
      InboundConnectionMetadata connectionMetadata = atConnection.metaData;
      expect(connectionMetadata.from, true);
      expect(connectionMetadata.fromAtSign, '@bob');
    });

    test('test from verb handler to allow fromAtSign first and then block',
        () async {
      var verbHandler = FromVerbHandler(keyValueStore, commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl().currentAtSign = alice;
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(null, inBoundSessionId);
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent('atSign', () => '@bob');
      var response = Response();
      await verbHandler.processVerb(response, verbParams, atConnection);
      expect(response.data.startsWith('proof:$inBoundSessionId@bob'), true);
      InboundConnectionMetadata connectionMetadata = atConnection.metaData;
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

  tearDownAll(() async => await tearDownFunc());

  if (Directory(storageDir).existsSync()) {
    Directory(storageDir).deleteSync(recursive: true);
  }
}

/// A [DummyInboundConnection] that records whether it was closed.
class _ClosableConnection extends DummyInboundConnection {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}

final HiveAtPersistenceFactory _fromTestFactory = HiveAtPersistenceFactory();

Future<AtKeyValueStore<String, AtData, AtMetaData?>> setUpFunc(
    storageDir) async {
  final bundle = await _fromTestFactory.initialize(
    alice,
    HivePersistenceConfig(
      storagePath: storageDir,
      commitLogPath: storageDir,
      accessLogPath: storageDir,
      notificationStoragePath: storageDir,
    ),
  );

  AtSecondaryServerImpl.getInstance().currentAtSign = alice;
  atCommitLog = bundle.keyValueStore.commitLog!;
  atAccessLog = bundle.accessLog!;
  AtSecondaryServerImpl.getInstance().commitLog = atCommitLog;
  AtSecondaryServerImpl.getInstance().accessLog = atAccessLog;
  return bundle.keyValueStore;
}

Future<void> tearDownFunc() async {
  await _fromTestFactory.close();
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
