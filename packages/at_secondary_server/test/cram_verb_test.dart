import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late AtKeyValueStore<String, AtData, AtMetaData?> mockKeyStore;
  late FakeSocket mockSocket;

  verbTestsSetUpLogging();

  late AtKeyValueStore<String, AtData, AtMetaData?> keyValueStore;
  setUp(() async {
    mockKeyStore = MockAtKeyValueStore();
    mockSocket = FakeSocket();
    keyValueStore = await setUpFunc(storageDir);
  });

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
      var handler = CramVerbHandler(mockKeyStore, accessLog: atAccessLog);
      expect(handler.accept(command), true);
    });
    test('test from accept invalid keyword', () {
      var command = 'cramer:';
      var handler = CramVerbHandler(mockKeyStore, accessLog: atAccessLog);
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
      var verbHandler = CramVerbHandler(keyValueStore, accessLog: atAccessLog);
      var verb = verbHandler.getVerb();
      expect(verb is Cram, true);
    });

    test('test cram verb handler processVerb auth success', () async {
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyValueStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign =
          '@test_user_1'.toAtsign();
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst(RegExp('^data:'), '');
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}$fromResponse';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var verbHandler = CramVerbHandler(keyValueStore, accessLog: atAccessLog);
      var cramResponse = Response();
      await verbHandler.processVerb(cramResponse, cramVerbParams, atConnection);
      var connectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      expect(connectionMetadata.isAuthenticated, true);
      expect(cramResponse.data, 'success');
    });

    test('test cram verb handler processVerb auth fail', () async {
      var secretData = AtData();
      secretData.data =
          'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
      await keyValueStore.put('privatekey:at_secret', secretData);
      var fromVerbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign =
          '@test_user_1'.toAtsign();
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var cramVerbParams = HashMap<String, String>();
      var combo = '${secretData.data}random_from_response';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var verbHandler = CramVerbHandler(keyValueStore, accessLog: atAccessLog);
      var cramResponse = Response();
      var connectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      expect(
          () async => await verbHandler.processVerb(
              cramResponse, cramVerbParams, atConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
      expect(connectionMetadata.isAuthenticated, false);
    });

    test(
        'test cram verb handler rejects an empty secret (null-replant backdoor)',
        () async {
      // Simulate a secondary where privatekey:at_secret was re-planted with an
      // empty/null value (e.g. restart without -s after the deleted-marker was
      // removed). The digest is then computable from public session data, so
      // the server must refuse to authenticate.
      await keyValueStore.put('privatekey:at_secret', AtData()..data = '');
      var fromVerbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign =
          '@test_user_1'.toAtsign();
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var fromResponse = response.data!.replaceFirst(RegExp('^data:'), '');
      // The digest an attacker would compute against an empty secret.
      var cramVerbParams = HashMap<String, String>();
      var digest = sha512.convert(utf8.encode(fromResponse));
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var verbHandler = CramVerbHandler(keyValueStore, accessLog: atAccessLog);
      var connectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      expect(
          () async => await verbHandler.processVerb(
              Response(), cramVerbParams, atConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
      expect(connectionMetadata.isAuthenticated, false);
    });

    test('test cram verb handler processVerb no secret in keystore', () async {
      var fromVerbHandler = FromVerbHandler(keyValueStore,
          commitLog: atCommitLog, accessLog: atAccessLog);
      AtSecondaryServerImpl.getInstance().currentAtSign =
          '@test_user_1'.toAtsign();
      var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      var fromVerbParams = HashMap<String, String>();
      fromVerbParams.putIfAbsent('atSign', () => 'test_user_1');
      var response = Response();
      await fromVerbHandler.processVerb(response, fromVerbParams, atConnection);
      var cramVerbParams = HashMap<String, String>();
      var combo = 'random_string';
      var bytes = utf8.encode(combo);
      var digest = sha512.convert(bytes);
      cramVerbParams.putIfAbsent('digest', () => digest.toString());
      var verbHandler = CramVerbHandler(keyValueStore, accessLog: atAccessLog);
      var cramResponse = Response();
      var connectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      expect(
          () async => await verbHandler.processVerb(
              cramResponse, cramVerbParams, atConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
      expect(connectionMetadata.isAuthenticated, false);
    });
  });

  /// Issues a challenge on [connection] with `from:` and returns the digest
  /// that answers it with this atSign's CRAM secret.
  Future<String> answerableDigest(DummyInboundConnection connection) async {
    const secret =
        'b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43b'
        'c55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364';
    await keyValueStore.put('privatekey:at_secret', AtData()..data = secret);
    AtSecondaryServerImpl.getInstance().currentAtSign =
        '@test_user_1'.toAtsign();
    connection.metaData.sessionID =
        '_${DateTime.now().microsecondsSinceEpoch}';
    final response = Response();
    await FromVerbHandler(keyValueStore,
            commitLog: atCommitLog, accessLog: atAccessLog)
        .processVerb(response,
            HashMap<String, String>()..['atSign'] = 'test_user_1', connection);
    final challenge = response.data!.replaceFirst(RegExp('^data:'), '');
    return sha512.convert(utf8.encode('$secret$challenge')).toString();
  }

  group('Given a connection that has authenticated with pkam', () {
    for (final AuthType authType in [AuthType.pkamLegacy, AuthType.apkam]) {
      test(
          'when it sends cram:, then it is refused with AT0009 and closed '
          '($authType)', () async {
        final connection = _ClosableConnection();
        connection.metaData
          ..isAuthenticated = true
          ..authType = authType;
        final digest = await answerableDigest(connection);

        await CramVerbHandler(keyValueStore, accessLog: atAccessLog)
            .process('cram:$digest', connection);

        expect(
            connection.lastWrittenData,
            startsWith('error:AT0009:cram may not follow a successful pkam on '
                'this connection'));
        expect(connection.closed, isTrue);
        expect(connection.metaData.authType, authType);
      });
    }
  });

  group('Given a connection that has not authenticated, or has with cram', () {
    for (final AuthType? authType in [null, AuthType.cram]) {
      test('when it sends cram:, then the cram runs as usual ($authType)',
          () async {
        final connection = _ClosableConnection();
        connection.metaData
          ..isAuthenticated = authType != null
          ..authType = authType;
        final digest = await answerableDigest(connection);

        await CramVerbHandler(keyValueStore, accessLog: atAccessLog)
            .process('cram:$digest', connection);

        expect(connection.lastWrittenData, startsWith('data:success'));
        expect(connection.closed, isFalse);
        expect(connection.metaData.authType, AuthType.cram);
      });
    }
  });

  tearDownAll(() async => await tearDownFunc());
}

class _ClosableConnection extends DummyInboundConnection {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}

final HiveAtPersistenceFactory _cramTestFactory = HiveAtPersistenceFactory();

Future<AtKeyValueStore<String, AtData, AtMetaData?>> setUpFunc(
    storageDir) async {
  final bundle = await _cramTestFactory.initialize(
    '@test_user_1',
    HivePersistenceConfig(
      storagePath: storageDir,
      commitLogPath: storageDir,
      accessLogPath: storageDir,
      notificationStoragePath: storageDir,
    ),
  );

  atCommitLog = bundle.keyValueStore.commitLog!;
  atAccessLog = bundle.accessLog!;
  AtSecondaryServerImpl.getInstance().commitLog = atCommitLog;
  AtSecondaryServerImpl.getInstance().accessLog = atAccessLog;
  return bundle.keyValueStore;
}

Future<void> tearDownFunc() async {
  await _cramTestFactory.close();
  var isExists = await Directory(storageDir).exists();
  if (isExists) {
    Directory(storageDir).deleteSync(recursive: true);
  }
}
