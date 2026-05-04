import 'dart:collection';
import 'dart:convert';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  FakeSocket mockSocket = FakeSocket();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
    inboundConnection.metaData.isAuthenticated = true;
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

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
      var handler = SyncProgressiveVerbHandler(secondaryKeyStore);
      expect(handler.accept(command), true);
    });
    test('test sync accept invalid keyword', () {
      var command = 'syncing:1';
      var handler = SyncProgressiveVerbHandler(secondaryKeyStore);
      expect(handler.accept(command), false);
    });
    test('test sync verb upper case', () {
      var command = 'SYNC:from:5:limit:10';
      command = SecondaryUtil.convertCommand(command);
      var handler = SyncProgressiveVerbHandler(secondaryKeyStore);
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
    SyncProgressiveVerbHandler verbHandler;

    test('A test to verify sync metadata is populated correctly', () async {
      // Add data to commit log
      await atCommitLog.commit('phone.wavi$alice', CommitOp.UPDATE);
      //Add data to keystore
      await secondaryKeyStore.put(
          'phone.wavi$alice',
          AtData()
            ..data = '+9189877783232'
            ..metaData = (AtMetaData()
              ..ttl = 10000
              ..ttb = 1000
              ..ttr = 100
              ..isBinary = false
              ..encoding = 'base64'
              ..pubKeyHash =
                  PublicKeyHash('dummy_hash', HashingAlgoType.sha512.name)
              ..pubKeyCS = 'dummy_pub_key_cs'));

      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      var response = Response();
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '0');
      verbParams.putIfAbsent('limit', () => '10');
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      await verbHandler.processVerb(response, verbParams, atConnection);

      Map syncResponseMap = (jsonDecode(response.data!)).first;
      expect(syncResponseMap['atKey'], 'phone.wavi$alice');
      expect(syncResponseMap['value'], '+9189877783232');
      expect(syncResponseMap['commitId'], 1);
      expect(syncResponseMap['operation'], '*');
      expect(syncResponseMap['metadata']['ttl'], '10000');
      expect(syncResponseMap['metadata']['ttb'], '1000');
      expect(syncResponseMap['metadata']['ttr'], '100');
      expect(syncResponseMap['metadata']['isBinary'], 'false');
      expect(syncResponseMap['metadata']['encoding'], 'base64');
      expect(syncResponseMap['metadata']['pubKeyCS'], 'dummy_pub_key_cs');
      expect(syncResponseMap['metadata']['pubKeyHash'],
          '{"hash":"dummy_hash","hashingAlgo":"sha512"}');
    });

    test('test to ensure at least one entry is synced always', () async {
      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);

      // generate some commit entries
      await secondaryKeyStore.put(
          'test_key_alpha$alice', AtData()..data = 'ALPHA');
      await secondaryKeyStore.put(
          'test_key2_beta$alice', AtData()..data = 'BETA');
      // ensure commitLog is not empty
      assert(atCommitLog.entriesCount() > 0);

      List<KeyStoreEntry> syncResponse = [];
      await verbHandler.prepareResponse(
        0,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 0),
      );
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key_alpha$alice');
    });

    test(
        'overflowing entry not added to syncResponse when syncResponse not empty',
        () async {
      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      List<KeyStoreEntry> syncResponse = [];

      // generate some commit entries
      await secondaryKeyStore.put(
          'test_key_alpha$alice', AtData()..data = 'ALPHA');
      await secondaryKeyStore.put(
          'test_key2_beta$alice', AtData()..data = 'BETA');
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
        0,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 0),
      );
      expect(syncResponse, [entry]);

      syncResponse.clear();
      await verbHandler.prepareResponse(
        0,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 0),
      );
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key_alpha$alice');

      syncResponse.clear();
      await verbHandler.prepareResponse(
        0,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 1),
      );
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key2_beta$alice');
    });

    test('test to ensure all entries are synced if buffer does not overflow',
        () async {
      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);

      // generate some commit entries
      await secondaryKeyStore.put(
          'test_key_alpha$alice', AtData()..data = 'ALPHA');
      await secondaryKeyStore.put(
          'test_key2_beta$alice', AtData()..data = 'BETA');
      await secondaryKeyStore.put('abcd$alice', AtData()..data = 'ABCD');
      await secondaryKeyStore.put(
          'another_random_key$alice', AtData()..data = 'RANDOM');

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
        10 * 1024 * 1024,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 0),
      );

      // Expecting that all the entries in the commitLog have been
      // added to syncResponse
      expect(syncResponse.length, commitLogLength + 1);
      expect(syncResponse[0], entry);
      expect(syncResponse[1].key, 'test_key_alpha$alice');
      expect(syncResponse[2].key, 'test_key2_beta$alice');
      expect(syncResponse[3].key, 'abcd$alice');
      expect(syncResponse[4].key, 'another_random_key$alice');
    });

    test(
        'ensure only one overflowing entry is added to syncResponse when commitLog has two large entries',
        () async {
      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      // generate some commit entries
      await secondaryKeyStore.put('test_key_1$alice', AtData()..data = 'ONE');
      await secondaryKeyStore.put('test_key_2$alice', AtData()..data = 'TWO');

      // ensure commitLog is not empty
      assert(atCommitLog.entriesCount() == 2);

      List<KeyStoreEntry> syncResponse = [];
      await verbHandler.prepareResponse(
        0,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 0),
      );
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key_1$alice');

      syncResponse.clear();
      await verbHandler.prepareResponse(
        0,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 1),
      );
      expect(syncResponse.length, 1);
      expect(syncResponse[0].key, 'test_key_2$alice');

      // test with empty iterator
      syncResponse.clear();
      await verbHandler.prepareResponse(
        10 * 1024 * 1024,
        AtSecondaryConfig.syncPageLimit,
        syncResponse,
        atCommitLog.iterate(fromCommitId: 2),
      );
      expect(syncResponse.length, 0);
    });

    test(
        'A test to verify sync returns default number of entries when limit is not passed',
        () async {
      // Add data to commit log
      await atCommitLog.commit('phone.wavi$alice', CommitOp.UPDATE);
      //Add data to keystore
      var metadata = (AtMetaData()
        ..ttl = 10000
        ..ttb = 1000
        ..ttr = 100
        ..isBinary = false
        ..encoding = 'base64'
        ..pubKeyHash = PublicKeyHash('dummy_hash', HashingAlgoType.sha512.name)
        ..pubKeyCS = 'dummy_pub_key_cs');
      for (int i = 1; i <= 40; i++) {
        await secondaryKeyStore.put(
            'random_$i.wavi$alice',
            AtData()
              ..data = i.toString()
              ..metaData = metadata);
      }

      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      var response = Response();
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '0');
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      await verbHandler.processVerb(response, verbParams, atConnection);

      var syncResponseList = jsonDecode(response.data!);
      expect(syncResponseList.length, 25);
      for (int i = 0; i < syncResponseList.length; i++) {
        expect(syncResponseList[i]['atKey'], 'random_${i + 1}.wavi$alice');
      }
    });

    test(
        'A test to verify sync returns correct number of entries when limit (less than default size) is passed',
        () async {
      // Add data to commit log
      await atCommitLog.commit('phone.wavi$alice', CommitOp.UPDATE);
      //Add data to keystore
      var metadata = (AtMetaData()
        ..ttl = 10000
        ..ttb = 1000
        ..ttr = 100
        ..isBinary = false
        ..encoding = 'base64'
        ..pubKeyHash = PublicKeyHash('dummy_hash', HashingAlgoType.sha512.name)
        ..pubKeyCS = 'dummy_pub_key_cs');
      for (int i = 1; i <= 40; i++) {
        await secondaryKeyStore.put(
            'random_$i.wavi$alice',
            AtData()
              ..data = i.toString()
              ..metaData = metadata);
      }

      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      var response = Response();
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '0');
      verbParams.putIfAbsent(AtConstants.syncLimit, () => '12');
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      await verbHandler.processVerb(response, verbParams, atConnection);

      var syncResponseList = jsonDecode(response.data!);
      expect(syncResponseList.length, 12);
      for (int i = 0; i < syncResponseList.length; i++) {
        expect(syncResponseList[i]['atKey'], 'random_${i + 1}.wavi$alice');
      }
    });
    test(
        'A test to verify sync returns correct number of entries when limit (greater than default size) is passed',
        () async {
      // Add data to commit log
      await atCommitLog.commit('phone.wavi$alice', CommitOp.UPDATE);
      //Add data to keystore
      var metadata = (AtMetaData()
        ..ttl = 10000
        ..ttb = 1000
        ..ttr = 100
        ..isBinary = false
        ..encoding = 'base64'
        ..pubKeyHash = PublicKeyHash('dummy_hash', HashingAlgoType.sha512.name)
        ..pubKeyCS = 'dummy_pub_key_cs');
      for (int i = 1; i <= 40; i++) {
        await secondaryKeyStore.put(
            'random_$i.wavi$alice',
            AtData()
              ..data = i.toString()
              ..metaData = metadata);
      }

      verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      var response = Response();
      var verbParams = HashMap<String, String>();
      verbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '0');
      verbParams.putIfAbsent(AtConstants.syncLimit, () => '35');
      var inBoundSessionId = '123';
      var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
      await verbHandler.processVerb(response, verbParams, atConnection);

      var syncResponseList = jsonDecode(response.data!);
      expect(syncResponseList.length, 35);
      for (int i = 0; i < syncResponseList.length; i++) {
        expect(syncResponseList[i]['atKey'], 'random_${i + 1}.wavi$alice');
      }
    });
  });

  group(
      'A group of regression tests for the auth-filter empty-response wedge (Phase 3.5d)',
      () {
    late String enrollmentId;

    setUp(() async {
      // APKAM connection enrolled for namespace 'wavi' read-only.
      // Keys in other namespaces will be filtered out by isAuthorized,
      // exercising the iterate(where:) closure's auth path.
      inboundConnection.metadata.isAuthenticated = true;
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await secondaryKeyStore.put(
          '$enrollmentId.new.enrollments.__manage$alice',
          AtData()..data = jsonEncode(enrollJson));
    });

    test(
        'all-unauthorized 25-entry window: response stays empty AND scan completes in bounded time',
        () async {
      // Seed 25 entries in a namespace the connection is NOT enrolled
      // for. Pre-3.5d, the verb handler would scan only the first 25
      // commit entries and return [], wedging the client because the
      // commitId watermark could not advance.
      for (int i = 0; i < 25; i++) {
        await secondaryKeyStore.put(
            'k$i.unauthorized$alice', AtData()..data = 'v$i');
      }
      expect(atCommitLog.entriesCount(), 26); // 25 keys + the enrollment record

      final verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      final response = Response();
      final verbParams = HashMap<String, String>();
      verbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
      verbParams.putIfAbsent(AtConstants.syncLimit, () => '25');
      final stopwatch = Stopwatch()..start();
      await verbHandler.processVerb(response, verbParams, inboundConnection);
      stopwatch.stop();

      // The bug-fixed invariant: stream-end is hit; response is [].
      // Critical regression assertion: this completes in bounded time
      // (one full scan), not the ad-infinitum loop the previous
      // limit-based impl was vulnerable to.
      final list = jsonDecode(response.data!) as List;
      expect(list, isEmpty);
      expect(stopwatch.elapsed.inSeconds, lessThan(1));
    });

    test(
        'authorized entry past unauthorized run: scan walks past the filtered window and returns the survivor',
        () async {
      // Seed 25 unauthorized entries, then one authorized entry. Pre-3.5d
      // would scan only the first 25 (all filtered) and miss the 26th.
      for (int i = 0; i < 25; i++) {
        await secondaryKeyStore.put(
            'k$i.unauthorized$alice', AtData()..data = 'v$i');
      }
      await secondaryKeyStore.put(
          'phone.wavi$alice', AtData()..data = '+12025551234');

      final verbHandler = SyncProgressiveVerbHandler(secondaryKeyStore);
      final response = Response();
      final verbParams = HashMap<String, String>();
      verbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
      verbParams.putIfAbsent(AtConstants.syncLimit, () => '25');
      await verbHandler.processVerb(response, verbParams, inboundConnection);

      // Exactly the one authorized entry is returned. The 25 unauthorized
      // entries are silently skipped during the scan.
      final list = jsonDecode(response.data!) as List;
      expect(list.length, 1);
      expect(list.first['atKey'], 'phone.wavi$alice');
      expect(list.first['value'], '+12025551234');
    });
  });
}
