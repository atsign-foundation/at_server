import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

// How the server processes updates from the client (including the responses it generates) and what the expectations
// are - i.e. can we reject? what happens when we reject? and more
// How items are added to the commit log on the server such that they are available for sync to the clients
// How the server processes that log (when sending updates to client) - e.g. again ordering, de-duping, etc
String atSign = alice;

void main() async {
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
  AtCacheManager mockAtCacheManager = MockAtCacheManager();
  FakeSocket mockSocket = FakeSocket();
  NotificationManager mockNotificationManager = MockNotificationManager();

  verbTestsSetUpLogging();

  Future<String> putData(String key) async {
    final data = Uuid().v4();
    await keyValueStore.put(key, AtData()..data = data);
    return data;
  }

  Future<String> putMetaData(String key, AtMetaData md) async {
    final data = Uuid().v4();
    await keyValueStore.putMeta(key, md);
    return data;
  }

  group(
      'A group of tests to validate how server process the updates from the client',
      () {
    group('A group of tests for various commit entry operations', () {
      setUp(() async {
        await verbTestsSetUp();
      });
      test('verify the behaviour of server when client send an update',
          () async {
        ///Precondition
        /// 1. The key should NOT be present in the keystore.
        ///
        /// Assertions:
        /// 1. A new key is created in the keystore
        /// 2. The version of the key is set to 0 (zero)
        /// 3. The "createdAt" is less than now()
        /// 4. The "createdBy" is assigned to currentAtSign
        /// 5. The entry in commitLog should be created with CommitOp.Update
        // Setup
        DateTime start = DateTime.now();
        await putData('$alice:phone$alice');
        // verify metadata
        AtMetaData md =
            (await keyValueStore.get('$alice:phone$alice'))!.metaData!;
        expect(md.createdAt!.difference(start).inMicroseconds, isPositive);
        expect(md.updatedAt!.difference(start).inMicroseconds, isPositive);
        expect(md.version, 0);
        expect(md.createdBy, atSign);
        // verify commit entry data
        final entry = await atCommitLog.iterate().first;
        expect(entry.operation, CommitOp.UPDATE);
        expect(entry.commitId, 0);
      });

      try {
        test(
            'test to verify when the commit entry is update on an existing key and data in hive store and latestCommitId of a key should be updated',
            () async {
          ///Precondition
          /// 1. Insert a new key into the keystore
          /// 2. Update the same key metadata and value
          ///
          /// Assertions:
          /// 1. CommitEntry Operation is set to "UPDATE_ALL"
          /// 2. The value and metadata of the existing key should be updated
          /// 3. The commit log should have a new entry
          /// 4. The version of the key is set to 1
          /// 5. The "createdAt" is less than now()
          /// 6. The "updatedAt" is populated and is less than now()
          /// 7. The "createdBy" is assigned to currentAtSign
          // Inserting a new key into keystore
          var keyCreationDateTime = DateTime.now().toUtc();
          await putData('$alice:phone$alice');
          // Assert commit entry before update
          var entry = await atCommitLog.iterate().first;
          expect(entry.atKey, '$alice:phone$alice');
          expect(entry.commitId, 0);
          // Update the same key again
          var keyUpdateDateTime = DateTime.now().toUtc();
          await keyValueStore.put(
              '$alice:phone$alice',
              AtData()
                ..data = '345'
                ..metaData = (AtMetaData()..ttl = 10000));
          // Assert the metadata
          AtData? atDataAfterUpdate =
              await keyValueStore.get('$alice:phone$alice');
          expect(atDataAfterUpdate!.data, '345');
          expect(atDataAfterUpdate.metaData!.ttl, 10000);
          expect(atDataAfterUpdate.metaData!.version, 1);
          expect(atDataAfterUpdate.metaData!.createdBy, atSign);
          expect(
              atDataAfterUpdate.metaData!.createdAt!.millisecondsSinceEpoch >=
                  keyCreationDateTime.millisecondsSinceEpoch,
              true);
          expect(
              atDataAfterUpdate.metaData!.updatedAt!.millisecondsSinceEpoch >=
                  keyUpdateDateTime.millisecondsSinceEpoch,
              true);
          await for (final entry in atCommitLog.iterate()) {
            expect(entry.operation, CommitOp.UPDATE_ALL);
            expect(entry.commitId, 1);
          }
        });
      } catch (e, s) {
        print(s);
      }

      test(
          'test to verify when the commit entry is update_meta, the key metadata alone is updated',
          () async {
        ///Precondition
        /// 1. Insert a new key into the keystore
        /// 2. Update only metadata of the same key
        ///
        /// Assertions:
        /// 1. A new key is created in the hive keystore
        /// 2. The commit log should have a new entry
        /// 3. The version of the key is set to 1
        /// 4. The "createdAt" is less than now()
        /// 5. The "updatedAt" is populated and is less than now()
        /// 6. The "createdBy" is assigned to currentAtSign
        /// 7. update_meta commit entry is received where commit entry contains change in metadata fields
        // Inserting a new key into keystore
        var keyCreationDateTime = DateTime.now().toUtc();
        await putData('$alice:phone$alice');
        // Updating the existing key
        var keyUpdateDateTime = DateTime.now().toUtc();
        await putMetaData('$alice:phone$alice', AtMetaData()..ttl = 10000);
        // verify the metadata
        AtData? atData = await keyValueStore.get('$alice:phone$alice');
        expect(
            atData!.metaData!.createdAt!.millisecondsSinceEpoch >=
                keyCreationDateTime.millisecondsSinceEpoch,
            true);
        expect(
            atData.metaData!.updatedAt!.millisecondsSinceEpoch >=
                keyUpdateDateTime.millisecondsSinceEpoch,
            true);
        expect(atData.metaData!.version, 1);
        expect(atData.metaData!.createdBy, atSign);
        expect(atData.metaData!.ttl, 10000);
        // Verify commit entry
        CommitEntry? commitEntryList =
            atCommitLog.getLatestCommitEntry('$alice:phone$alice');
        expect(commitEntryList!.operation, CommitOp.UPDATE_META);
        expect(commitEntryList.commitId, 1);
      });

      test(
          'test to verify when the commit entry is delete, the key is deleted from hive keystore and entry added to commit log',
          () async {
        ///Precondition
        /// 1. Insert a new key into the keystore
        /// 2. Delete same key from the keystore
        ///
        /// Assertions:
        /// 1. The key should be deleted from the keystore
        /// 2. The commit log should be updated with a new commit entry where CommitOperation is delete
        await putData('$alice:phone$alice');
        await keyValueStore.remove('$alice:phone$alice');
        // Verify key does not exist in the keystore
        var isKeyExist = await keyValueStore.exists('$alice:phone$alice');
        expect(isKeyExist, false);
        // Verify commit entry
        await for (final entry in atCommitLog.iterate()) {
          expect(entry.operation, CommitOp.DELETE);
          expect(entry.commitId, 1);
        }
      });
      test(
          'test to verify deletion of a non existent in the cloud secondary adds new commit entry',
          () async {
        ///Precondition
        /// 1. Delete a non existent key
        ///
        /// Assertions:
        /// A new entry associated with the key should be added to commit log with CommitOp.Delete
        await keyValueStore.remove('$alice:mobile$alice');
        // Verify key does not exist in the keystore
        var isKeyExist = await keyValueStore.exists('$alice:mobile$alice');
        expect(isKeyExist, false);
        // Verify commit entry
        await for (final entry in atCommitLog.iterate()) {
          expect(entry.operation, CommitOp.DELETE);
          expect(entry.commitId, 0);
        }
      });
      tearDown(() async => await verbTestsTearDown());
    });
    group('A group of tests related to batch processing', () {
      setUp(() async => await verbTestsSetUp());
      test(
          'test to verify for the items in batch request respective commit ids are added to the batch response',
          () async {
        /// Preconditions
        /// 1. Add a few entries to the batch request with valid keys
        ///
        /// Assertions
        /// 1. Assert the batch response. Decode the batch response list and length
        /// of list should be equal to the number of batch requests
        /// 2. The commit-id's should be incremented sequentially
        /// 3. Assert the data and metadata updated to keystore
        VerbHandlerManager verbHandlerManager = DefaultVerbHandlerManager(
            keyValueStore,
            mockOutboundClientManager,
            mockAtCacheManager,
            statsNotificationService,
            mockNotificationManager,
            enMgr,
            alice,
            commitLog: atCommitLog,
            accessLog: atAccessLog);
        var batchRequestCommand = jsonEncode([
          BatchRequest(100, 'update:city$alice copenhagen'),
          BatchRequest(456, 'delete:phone$alice'),
          BatchRequest(341,
              'update:dataSignature:dummy_data_signature:public:country$alice denmark'),
          BatchRequest(442,
              'update:ttl:1000:ttb:2000:ttr:3000:ccd:true:mobile$alice 1234')
        ]);
        // Process Batch request
        var batchVerbHandler =
            BatchVerbHandler(keyValueStore, verbHandlerManager);

        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var response = Response();
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var batchVerbParams = HashMap<String, String>();
        batchVerbParams.putIfAbsent('json', () => batchRequestCommand);
        await batchVerbHandler.processVerb(
            response, batchVerbParams, atConnection);
        List batchResponseList = jsonDecode(response.data!);

        // Assertions
        expect(batchResponseList.length, 4);
        expect(batchResponseList[0]['response']['data'], '0');
        expect(batchResponseList[1]['response']['data'], '1');
        expect(batchResponseList[2]['response']['data'], '2');
        expect(batchResponseList[3]['response']['data'], '3');
        // Assert the data stored in the keystore
        var atData = await keyValueStore.get('city$alice');
        expect(atData!.data, 'copenhagen');
        // Assert the data and metadata stored in the keystore
        atData = await keyValueStore.get('mobile$alice');
        expect(atData!.data, '1234');
        expect(atData.metaData!.ttl, 1000);
        expect(atData.metaData!.ttb, 2000);
        expect(atData.metaData!.ttr, 3000);
        expect(atData.metaData!.isCascade, true);
        // Assert the data and metadata of a public key
        atData = await keyValueStore.get('public:country$alice');
        expect(atData!.data, 'denmark');
        expect(atData.metaData!.dataSignature, 'dummy_data_signature');
        // Assert the key is removed on delete operation
        expect(await keyValueStore.exists('phone$alice'), false);
      });

      test('test to verify when one of the command in batch has invalid syntax',
          () async {
        /// Preconditions
        /// 1. Server receives the batch request with an invalid command
        ///
        /// Assertions
        /// 1. The valid commands should be processed and commit-id should be added to batch response
        /// 2. For the invalid batch request command, the error code and error message should be updated in the batch response
        VerbHandlerManager verbHandlerManager = DefaultVerbHandlerManager(
            keyValueStore,
            mockOutboundClientManager,
            mockAtCacheManager,
            statsNotificationService,
            mockNotificationManager,
            enMgr,
            alice,
            commitLog: atCommitLog,
            accessLog: atAccessLog);
        var batchRequestCommand = jsonEncode([
          BatchRequest(1, 'delete:phone$alice'),
          BatchRequest(2, 'update:city$alice'),
          BatchRequest(3, 'update:public:country$alice denmark')
        ]);
        var batchVerbHandler =
            BatchVerbHandler(keyValueStore, verbHandlerManager);
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var response = Response();
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var batchVerbParams = HashMap<String, String>();
        batchVerbParams.putIfAbsent('json', () => batchRequestCommand);

        await batchVerbHandler.processVerb(
            response, batchVerbParams, atConnection);
        List batchResponseList = jsonDecode(response.data!);
        expect(batchResponseList.length, 3);
        expect(batchResponseList[0]['response']['data'], '0');
        expect(batchResponseList[1]['response']['error_code'], 'AT0003');
        expect(batchResponseList[1]['response']['error_message'],
            'Invalid syntax');
        expect(batchResponseList[2]['response']['data'], '1');
      });
      test('Test to verify when invalid json is sent in batch request', () {
        /// Preconditions:
        /// 1. The batch verb syntax is correct
        /// 2. The json value which contains entries to sync to server are of invalid JSON
        ///
        /// Assertions:
        /// Should we return an batch response with invalid format exception?
      });
      tearDown(() async => await verbTestsTearDown());
    });
  });

  group('A group of tests to verify on server sending updates to client', () {
    group('A group of tests related to sending data to client', () {
      setUp(() async {
        await verbTestsSetUp();
        // Setup data
        await putData('$alice:phone.wavi$alice');
        await putData('public:country.wavi$alice');
        await putData('@bob:file-transfer.mosphere$alice');
        await putData('firstName.buzz$alice');
      });
      test(
          'test to verify initial sync request fetch the latest commit entry when there are multiple commits entries for a key',
          () async {
        /// Preconditions:
        /// 1. The server keystore should contain valid keys (Keys are inserted in setUp function)
        /// 2. Sync request received: sync:from:-1:pageLimit:10
        ///
        /// Operation:
        /// Secondary server receives sync request
        ///
        /// Assertions:
        /// 1. The sync response should contain latest commit entries of the keys
        /// Below are the expected keys inorder
        ///    commitId:1 -  public:country.wavi$alice
        ///    commitId:2 -  @bob:file-transfer.mosphere$alice
        ///    commitId:3 -  firstName.buzz$alice
        ///    commitId:4 -  $alice:phone.wavi$alice
        // Updating the key again to have two entries for the same key.
        // The entry with highest commit should be returned.
        await putData('$alice:phone.wavi$alice');
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);

        expect(syncResponse[0]['atKey'], 'public:country.wavi$alice');
        expect(syncResponse[0]['commitId'], 1);
        expect(syncResponse[0]['operation'], '+');
        expect(syncResponse[0]['metadata']['version'], '0');

        expect(syncResponse[1]['atKey'], '@bob:file-transfer.mosphere$alice');
        expect(syncResponse[1]['commitId'], 2);
        expect(syncResponse[1]['operation'], '+');
        expect(syncResponse[1]['metadata']['version'], '0');

        expect(syncResponse[2]['atKey'], 'firstname.buzz$alice');
        expect(syncResponse[2]['commitId'], 3);
        expect(syncResponse[2]['operation'], '+');
        expect(syncResponse[2]['metadata']['version'], '0');

        expect(syncResponse[3]['atKey'], '$alice:phone.wavi$alice');
        expect(syncResponse[3]['commitId'], 4);
        expect(syncResponse[3]['operation'], '*');
      });

      test(
          'test to verify last delete commit entry is sent when skipDeletesUntil flag is set',
          () async {
        await putData('test_key_1$alice');
        await keyValueStore.remove('test_key_1$alice');
        await putData('test_key_2$alice');
        await keyValueStore.remove('test_key_2$alice');
        await putData('test_key_3$alice');
        await keyValueStore.remove('test_key_3$alice');
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '15');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        var syncResponseList = [];
        for (var entry in syncResponse) {
          syncResponseList.add(entry['atKey']);
        }
        expect(syncResponseList.contains('test_key_1$alice'), false);
        expect(syncResponseList.contains('test_key_2$alice'), false);
        expect(syncResponseList.contains('test_key_3$alice'), true);
      });

      test(
          'test to verify delete commit entries are not sent when skipDeletesUntil flag is set and only matching keys are sent when regex is set',
          () async {
        await putData('test_key_1.wavi$alice');
        await keyValueStore.remove('test_key_1.wavi$alice');
        await putData('test_key_2.buzz$alice');
        await keyValueStore.remove('test_key_2.buzz$alice');
        await putData('test_key_3.buzz$alice');
        await putData('test_key_4.wavi$alice');
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('regex', () => 'buzz');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '15');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        var syncResponseList = [];
        for (var entry in syncResponse) {
          syncResponseList.add(entry['atKey']);
        }
        expect(syncResponseList.contains('test_key_1.wavi$alice'), false);
        expect(syncResponseList.contains('test_key_2.buzz$alice'), false);
        expect(syncResponseList.contains('test_key_3.buzz$alice'), true);
        expect(syncResponseList.contains('test_key_4.wavi$alice'), false);
      });

      test(
          'test to verify last delete commit entry is NOT sent when skipDeletesUntil flag is set and key does not match regex',
          () async {
        await putData('test_key_1.wavi$alice');
        await keyValueStore.remove('test_key_1.wavi$alice');
        await putData('test_key_2.buzz$alice');
        await keyValueStore.remove('test_key_2.buzz$alice');
        await putData('test_key_3.buzz$alice');
        await putData('test_key_4.wavi$alice');
        await putData('test_key_5.buzz$alice');
        await keyValueStore.remove('test_key_4.wavi$alice');
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('regex', () => 'buzz');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '20');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        var syncResponseList = [];
        for (var entry in syncResponse) {
          syncResponseList.add(entry['atKey']);
        }
        expect(syncResponseList.contains('test_key_1.wavi$alice'), false);
        expect(syncResponseList.contains('test_key_2.buzz$alice'), false);
        expect(syncResponseList.contains('test_key_3.buzz$alice'), true);
        expect(syncResponseList.contains('test_key_5.buzz$alice'), true);
        // last commit entry should not be included since regex doesn't match
        expect(syncResponseList.contains('test_key_4.wavi$alice'), false);
      });

      test(
          'test to verify only entries matching the regex are added to sync response',
          () async {
        /// Preconditions:
        /// The Commit Log Keystore contains the keys
        ///
        /// Assertions
        /// The sync response contains the keys that matches the regex in sync request
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('regex', () => 'buzz');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);

        List syncResponse = jsonDecode(response.data!);

        expect(syncResponse.length, 1);

        expect(syncResponse[0]['atKey'], 'firstname.buzz$alice');
        expect(syncResponse[0]['commitId'], 3);
        expect(syncResponse[0]['operation'], '+');
        expect(syncResponse[0]['metadata']['version'], '0');
      });
      test('test to verify sync response does not exceed the buffer limit',
          () async {
        /// Preconditions:
        /// 1. Initialize the server keystore with valid keys
        /// 2. Override the sync buffer to a smaller value : 250 Bytes (Bytes to add single commit entry)
        /// 3. Sync command received from client: sync:from:-1:limit:10
        /// 4. Update the sync buffer size
        /// 5. On Updating the sync buffer size, all the keys should be returned in sync response
        ///
        /// Operations:
        /// Process sync verb
        ///
        /// Assertions:
        /// The sync response should not exceed the sync buffer size
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        // Setting buffer size to 250 Bytes
        syncProgressiveVerbHandler.capacity = 275;
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        expect(syncResponse.length, 1);

        // Increase the sync buffer size and assert all the 4 keys are added to sync response
        syncProgressiveVerbHandler.capacity = 1200;
        response = Response();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        syncResponse = jsonDecode(response.data!);
        expect(syncResponse.length, 4);
      });

      test('A test to verify invalid key is not added to the sync response',
          () async {
        // Inserting invalid key into the keystore. Since HiveKeyStore.put method as validation to
        // throw exception for invalid key, calling put method on the hive box.
        // and inserting the entry into the commit log
        // The "**" in the key - @invalidkey**.buzz$alice is added to set key as invalid key
        await (keyValueStore as HiveAtKeyValueStore)
            .getBox()
            .put('@invalidkey**.buzz$alice', AtData()..data = alice);
        AtCommitLog atCommitLog = (keyValueStore.commitLog) as HiveAtCommitLog;
        await atCommitLog.commit('@invalidkey**.buzz$alice', CommitOp.UPDATE);

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);

        List syncResponse = jsonDecode(response.data!);
        expect(syncResponse.length, 4);

        expect(syncResponse[0]['atKey'], "$alice:phone.wavi$alice");
        expect(syncResponse[0]['commitId'], 0);
        expect(syncResponse[0]['operation'], '+');
        expect(syncResponse[0]['metadata']['version'], '0');

        expect(syncResponse[1]['atKey'], 'public:country.wavi$alice');
        expect(syncResponse[1]['commitId'], 1);
        expect(syncResponse[1]['operation'], '+');
        expect(syncResponse[1]['metadata']['version'], '0');

        expect(syncResponse[2]['atKey'], '@bob:file-transfer.mosphere$alice');
        expect(syncResponse[2]['commitId'], 2);
        expect(syncResponse[2]['operation'], '+');
        expect(syncResponse[2]['metadata']['version'], '0');

        expect(syncResponse[3]['atKey'], 'firstname.buzz$alice');
        expect(syncResponse[3]['commitId'], 3);
        expect(syncResponse[3]['operation'], '+');
      });
      test(
          'A test to verify a commit entry whose key is absent from the keystore is skipped, not fatal',
          () async {
        // Reproduces the AT0015 sync failure: a commit entry outlives its
        // key (e.g. an expired key whose commit entry was not purged).
        // keyStore.get throws KeyNotFoundException rather than returning
        // null, so an unguarded fetch failed the entire sync request.
        AtCommitLog atCommitLog = (keyValueStore.commitLog) as HiveAtCommitLog;
        await atCommitLog.commit(
            'cached:$alice:orphaned.wavi$alice', CommitOp.UPDATE);

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var atConnection = InboundConnectionImpl(
            mockSocket, '_6665436c-29ff-481b-8dc6-129e89199718');
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');

        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);

        List syncResponse = jsonDecode(response.data!);
        // The four keys from setUp sync; the orphaned entry is skipped.
        expect(syncResponse.length, 4);
        expect(
            syncResponse
                .any((e) => e['atKey'] == 'cached:$alice:orphaned.wavi$alice'),
            false);
      });
      tearDown(() async => await verbTestsTearDown());
    });
    group('A group of test to validate the commit entry data', () {
      setUp(() async => await verbTestsSetUp());
      test('A test to verify commit entry data when commit operation is update',
          () async {
        /// Preconditions:
        /// 1. ServerCommitId is at 2
        /// 2. The entry to sync from server is "public:phone.wavi$alice" with commitOp.Update with metadata populated
        /// 3. sync command received: sync:from:1:limit:10
        ///
        /// Operations:
        /// Run Sync verb
        ///
        /// Assertions:
        /// 1. The sync response for the key should contains following fields
        ///    "atKey": "public:phone.wavi$alice",
        ///    "commitId": 0,
        ///    "operation": "*"

        PublicKeyHash somePubKeyHash = PublicKeyHash(
          'someHash',
          'someAlgo',
        );
        AtMetaData atMetadata = AtMetaData()
          ..ttl = 1000
          ..ttb = 2000
          ..ttr = 3000
          ..isCascade = true
          ..isEncrypted = true
          ..dataSignature = 'dummy_data_signature'
          ..sharedKeyEnc = 'dummy_shared_key'
          ..pubKeyCS = 'dummy_checksum'
          ..encoding = 'base64'
          ..encKeyName = 'an_encrypting_key_name'
          ..encAlgo = 'an_encrypting_algorithm_name'
          ..ivNonce = 'an_iv_or_nonce'
          ..skeEncKeyName =
              'an_encrypting_key_name_for_the_inlined_encrypted_shared_key'
          ..skeEncAlgo =
              'an_encrypting_algorithm_name_for_the_inlined_encrypted_shared_key'
          ..pubKeyHash = somePubKeyHash
          ..immutable = true;
        await keyValueStore.put(
            'public:phone.wavi$alice',
            AtData()
              ..data = '8897896765'
              ..metaData = atMetadata);
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);

        // Assert the data and metadata
        var firstResponse = syncResponseList[0];
        expect(firstResponse['atKey'], 'public:phone.wavi$alice');
        expect(firstResponse['commitId'], 0);
        expect(firstResponse['operation'], '*');
        var firstResponseMetadata = firstResponse['metadata'];
        expect(firstResponseMetadata['version'], '0');
        expect(firstResponseMetadata['ttl'], '1000');
        expect(firstResponseMetadata['ttb'], '2000');
        expect(firstResponseMetadata['ttr'], '3000');
        expect(firstResponseMetadata['ccd'], 'true');
        expect(firstResponseMetadata['dataSignature'], 'dummy_data_signature');
        expect(firstResponseMetadata['sharedKeyEnc'], 'dummy_shared_key');
        expect(firstResponseMetadata['pubKeyCS'], 'dummy_checksum');
        expect(firstResponseMetadata['encoding'], 'base64');
        expect(firstResponseMetadata['encKeyName'], 'an_encrypting_key_name');
        expect(
            firstResponseMetadata['encAlgo'], 'an_encrypting_algorithm_name');
        expect(firstResponseMetadata['ivNonce'], 'an_iv_or_nonce');
        expect(firstResponseMetadata['skeEncKeyName'],
            'an_encrypting_key_name_for_the_inlined_encrypted_shared_key');
        expect(firstResponseMetadata['skeEncAlgo'],
            'an_encrypting_algorithm_name_for_the_inlined_encrypted_shared_key');
        expect(firstResponseMetadata['pubKeyHash'],
            jsonEncode(somePubKeyHash.toJson()));
        expect(firstResponseMetadata['immutable'], 'true');
        expect(firstResponseMetadata['isEncrypted'], 'true');
      });

      test(
          'A test to verify commit entry data when commit operation is update_meta',
          () async {
        /// Preconditions:
        /// 1. ServerCommitId is at 2
        /// 2. The entry to sync from server is "public:phone.wavi$alice" with commitOp.Update
        /// 3. sync command received: sync:from:1:limit:10
        ///
        /// Operations:
        /// Run Sync verb
        ///
        /// Assertions:
        /// 1. The sync response for the key should contains following fields
        ///    "atKey": "public:phone.wavi$alice",
        ///    "metadata": <AtMetadata of the key>
        ///    "commitId": 2,
        ///    "operation": "#"
        ///    "version": 1
        String value = await putData('public:phone.wavi$alice');
        // Update the metadata alone
        await putMetaData(
            'public:phone.wavi$alice', (AtMetaData()..ttl = 1000));
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi$alice');
        expect(syncResponseList[0]['value'], value);
        expect(syncResponseList[0]['operation'], '#');
        expect(syncResponseList[0]['metadata']['version'], '1');
        expect(syncResponseList[0]['metadata']['ttl'], '1000');
      });

      test('A test to verify commit entry data when commit operation is delete',
          () async {
        /// Preconditions:
        /// 1. ServerCommitId is at 2
        /// 2. The entry to sync from server is "public:phone.wavi$alice" with commitOp.Update
        /// 3. sync command received: sync:from:1:limit:10
        ///
        /// Operations:
        /// Run Sync verb
        ///
        /// Assertions:
        /// 1. The sync response for the key should contains following fields
        ///    "atKey": "public:phone.wavi$alice",
        ///    "commitId": 2,
        ///    "operation": "-"
        await putData('public:phone.wavi$alice');
        // Delete the key
        await keyValueStore.remove('public:phone.wavi$alice');
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi$alice');
        expect(syncResponseList[0]['operation'], '-');
      });
      tearDown(() async => await verbTestsTearDown());
    });

    group('A group of tests on TTL and TTB with respect to sync', () {
      setUp(() async => await verbTestsSetUp());
      test(
          'test to verify when TTL of a key is expired and deleted then'
          ' there should be no commit entry', () async {
        /// Preconditions:
        /// 1. The key is created on server at time T1 with TTL set
        /// 2. The key is expired at time T2 (T2 > T1); and key is deleted from keystore
        /// 3. The sync triggers at time T3 (T3 > T2)
        /// 4. The key is deleted and commitLog should have a commitOp.delete
        ///
        /// Assertions:
        /// 1. The sync response should contain the commit entry of commitOp.delete
        String keyName = 'public:lastname.wavi$alice';
        await keyValueStore.put(
            keyName,
            AtData()
              ..data = '8897896765'
              ..metaData = (AtMetaData()..ttl = 1));
        await Future.delayed(Duration(milliseconds: 2));
        // manually trigger the deleteExpiredKeys to remove the expired keys
        await keyValueStore.deleteExpiredKeys();
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList, isEmpty);
        expect(
          keyValueStore.commitLog!.getLatestCommitEntry(keyName),
          isNull,
        );
      });

      test(
          'test to verify when TTL of a key is expired but not deleted when sync triggers',
          () {
        /// Preconditions:
        /// 1. The key is created on server at time T1
        /// 2. The key is expired at time T2 (T2 > T1); but key is still in keystore and not deleted
        /// 3. The sync triggers at time T3 (T3 > T2)
        ///
        ///
        /// TODO: When key is expired but not deleted, delete the key when a get operation is performed on the key
      });

      test('test to verify when the TTB of a key is active when sync triggers',
          () async {
        /// Preconditions:
        /// 1. The key is created on server at time T1 with TTB set
        /// 2. The key is expired at time T2 (T2 > T1); but key is still in keystore but not active
        /// 3. The sync triggers at time T3 (T3 > T2)
        ///
        /// Assertions:
        /// 1. The sync response should contain the commit entry of commitOp.Update
        ///
        /// When Time To Birth(TTB) is set, "data:null" will be returned when fetch for the key
        /// instead of original value until TTB is met.
        /// But when sync process, fetches the value, original value will be met even before the
        /// TTB is met.
        await keyValueStore.put(
            'public:phone.wavi$alice',
            AtData()
              ..data = '8897896765'
              ..metaData =
                  (AtMetaData()..ttb = Duration(minutes: 1).inMilliseconds));
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi$alice');
        expect(syncResponseList[0]['value'], '8897896765');
        expect(syncResponseList[0]['operation'], '*');
      });
      tearDown(() async => await verbTestsTearDown());
    });

    group('A group of tests on APKAM Enrollment', () {
      late SyncProgressiveVerbHandler handler;
      setUp(() async {
        await verbTestsSetUp();
        handler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
      });

      Future<List> executeSyncVerb(
        String enrollmentId, {
        String fromCommitId = '-1',
        String? skipDeletesUntil,
      }) async {
        var response = Response();
        inboundConnection.metaData.isAuthenticated = true;
        inboundConnection.metaData.enrollmentId = enrollmentId;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams[AtConstants.fromCommitSequence] = fromCommitId;
        if (skipDeletesUntil != null) {
          syncVerbParams[AtConstants.skipDeletesUntil] = skipDeletesUntil;
        }
        await handler.processVerb(response, syncVerbParams, inboundConnection);
        return jsonDecode(response.data!);
      }

      test('Verify sync with sub-namespace permissions', () async {
        // create data in wavi namespace and sub-namespaces
        String fooDotData = 'public:foo.data.wavi$alice';
        String fooDotKeys = 'public:foo.keys.wavi$alice';
        final waviKeys = [
          'public:phone.wavi$alice',
          'public:data.wavi$alice',
          fooDotData,
          'public:keys.wavi$alice',
          fooDotKeys,
          'public:other.wavi$alice',
          'public:foo.other.wavi$alice',
        ];
        for (final k in waviKeys) {
          await putData(k);
        }

        // create data in buzz namespace
        await putData('public:mobile.buzz$alice');

        List syncResponseList;

        // (1) namespace access: data.wavi:r
        final dataEn = await createAndPersistAnEnrollment(
            'wavi', 'pixel', {'data.wavi': 'r'});
        // should only get stuff from ".data.wavi"
        // and should not get "data.wavi"
        // since that's in the wavi namespace, not the data.wavi namespace
        syncResponseList = await executeSyncVerb(dataEn);
        expect(syncResponseList.length, 1);
        expect(syncResponseList[0]['atKey'], fooDotData);
        expect(syncResponseList[0]['operation'], '+');

        // (2) namespace access: keys.wavi:r
        final keysEn = await createAndPersistAnEnrollment(
            'wavi', 'pixel', {'keys.wavi': 'r'});
        // should only get stuff from ".keys.wavi"
        // and should not get "keys.wavi"
        // since that's in the wavi namespace, not the keys.wavi namespace
        syncResponseList = await executeSyncVerb(keysEn);
        expect(syncResponseList.length, 1);
        expect(syncResponseList[0]['atKey'], fooDotKeys);
        expect(syncResponseList[0]['operation'], '+');

        // (3) namespace access: wavi:rw
        final allEn =
            await createAndPersistAnEnrollment('wavi', 'pixel', {'wavi': 'rw'});
        // should get everything from ".wavi"
        syncResponseList = await executeSyncVerb(allEn);
        expect(syncResponseList.length, waviKeys.length);
        for (int i = 0; i < waviKeys.length; i++) {
          expect(syncResponseList[i]['atKey'], waviKeys[i]);
          expect(syncResponseList[i]['operation'], '+');
        }

        // (4) namespace access: data.wavi:rw, keys.wavi:rw
        final keysAndDataEn = await createAndPersistAnEnrollment(
          'wavi',
          'pixel',
          {'data.wavi': 'rw', 'keys.wavi': 'rw'},
        );
        // should get everything from "keys.wavi" and "data.wavi"
        //   => but nothing else from ".wavi"
        syncResponseList = await executeSyncVerb(keysAndDataEn);
        expect(syncResponseList.length, 2);
        expect(syncResponseList[0]['atKey'], fooDotData);
        expect(syncResponseList[0]['operation'], '+');
        expect(syncResponseList[1]['atKey'], fooDotKeys);
        expect(syncResponseList[1]['operation'], '+');
      });

      test('Verify sync with namespace permissions', () async {
        // create enrollment with wavi:rw
        final enrollmentId =
            await createAndPersistAnEnrollment('wavi', 'pixel', {'wavi': 'rw'});

        // create data in wavi namespace
        await putData('public:phone.wavi$alice');
        // create data in buzz namespace
        await putData('public:mobile.buzz$alice');

        // Verify that sync only returns data from the wavi namespace
        List syncResponseList = await executeSyncVerb(enrollmentId);
        expect(syncResponseList.length, 1);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi$alice');
        expect(syncResponseList[0]['operation'], '+');
      });

      test(
          'A test to verify all keys are returned when enrollment contains *:rw',
          () async {
        await putData('public:phone.wavi$alice');
        await putData('public:mobile.buzz$alice');
        var enrollmentId = await createAndPersistAnEnrollment(
            'wavi', 'pixel', {'wavi': 'rw', '*': 'rw'});

        List syncResponseList = await executeSyncVerb(enrollmentId);
        expect(syncResponseList.length, 2);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi$alice');
        expect(syncResponseList[0]['operation'], '+');
        expect(syncResponseList[1]['atKey'], 'public:mobile.buzz$alice');
        expect(syncResponseList[1]['operation'], '+');
      });

      tearDown(() async => await verbTestsTearDown());
    });
    group('A group of tests to verify skip deletes feature', () {
      setUp(() async => await verbTestsSetUp());
      test(
          'test to verify delete commit entries are not sent when skipDeletesUntil flag is set',
          () async {
        await putData('test_key_1$alice');
        await keyValueStore.remove('test_key_1$alice');
        await putData('test_key_2$alice');
        await keyValueStore.remove('test_key_2$alice');
        await putData('test_key_3$alice');
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '15');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        var syncResponseList = [];
        for (var entry in syncResponse) {
          syncResponseList.add(entry['atKey']);
        }
        expect(
            syncResponseList.contains('test_key_1$alice'), false); //deleted key
        expect(
            syncResponseList.contains('test_key_2$alice'), false); //deleted key
        expect(syncResponseList.contains('test_key_3$alice'), true);
      });

      test(
          'a test to verify sync response with skip deletes when first batch has all deletes',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 25; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '50');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        // deletes from commitID 25-49 should be skipped
        for (int i = 25; i < 49; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        // last delete should be sent
        expect(commitIdMap.containsKey(49), true);
        expect(commitIdMap[49], '-');
      });
      test(
          'a test to verify sync response with skip deletes when commit log has only deletes in second batch',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 25; i < 50; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 25; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '100');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 25; i < 50; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        response = Response();
        syncVerbParams[AtConstants.fromCommitSequence] = '49';
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '100');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        syncResponse = jsonDecode(response.data!);
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        //deletes from commitID 50-74 should be skipped
        for (int i = 50; i < 74; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        // last delete should be sent
        expect(commitIdMap.containsKey(74), true);
        expect(commitIdMap[74], '-');
      });
      test(
          'a test to verify sync response with skip deletes when last entry in first batch is delete',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 1; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '100');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 1; i < 25; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        // last delete should be sent
        expect(commitIdMap.containsKey(25), true);
        expect(commitIdMap[25], '-');
      });
      test(
          'a test to verify sync response - deletes after skipDeletesUntil should be sent',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 10; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '30');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 10; i < 25; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        // deletes till 30 should not be sent
        for (int i = 25; i <= 30; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        // rest of the deletes should be sent
        for (int i = 31; i <= 34; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '-');
        }
      });
      test(
          'a test to verify sync response with skip deletes when first entry in second batch is delete',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        await putData('test_key_25$alice');
        await keyValueStore.remove('test_key_25$alice');

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '50');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 0; i < 25; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        //get the next batch
        syncVerbParams[AtConstants.fromCommitSequence] = '24';
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '50');
        response = Response();
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        syncResponse = jsonDecode(response.data!);
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        // test_key_25 commitId should not be present in second batch
        expect(commitIdMap.containsKey(25), false);
        // last delete should be sent
        expect(commitIdMap.containsKey(26), true);
        expect(commitIdMap[26], '-');
      });

      test(
          'a test to verify sync response skipDeletesUntil is (last commit ID in batch - 1)',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 10; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '33');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 10; i < 25; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        // deletes till 33 should not be sent
        for (int i = 25; i <= 33; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        // last delete should be sent
        expect(commitIdMap.containsKey(34), true);
        expect(commitIdMap[34], '-');
      });
      test(
          'a test to verify sync response skipDeletesUntil is (last commit ID in batch)',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 10; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '34');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 10; i < 25; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        // deletes till 33 should not be sent
        for (int i = 25; i <= 33; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        // last delete should be sent even though skipDeleteUntil is 34
        expect(commitIdMap.containsKey(34), true);
        expect(commitIdMap[34], '-');
      });
      test(
          'a test to verify sync response skipDeletesUntil is (last commit ID in batch + 1)',
          () async {
        for (int i = 0; i < 25; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 10; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }
        for (int i = 25; i < 30; i++) {
          await putData('test_key_$i$alice');
        }

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '36');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 10; i < 25; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        // deletes till 34 should not be sent
        for (int i = 25; i <= 34; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        //updates from 35-39 should be sent
        for (int i = 35; i <= 39; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
      });
      test(
          'a test to verify sync response when skipDeletesUntil is accidentally set to a higher value greater than latest server commit id',
          () async {
        //1. creates commitId from 0-29
        for (int i = 0; i < 30; i++) {
          await putData('test_key_$i$alice');
        }
        //2. 10-29 commit id will be updates. 30-39 will be deletes since only one key entry will be maintained for update followed by delete.
        for (int i = 0; i < 10; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent(
            'skipDeletesUntil', () => '100'); //set to a higher value
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        var syncResponseList = [];
        var commitIdList = [];
        for (var entry in syncResponse) {
          syncResponseList.add(entry);
          commitIdList.add(entry['commitId']);
        }
        // should contain updates from commit id 10-29 and last commit id 39 which is delete. 30-38 will be skipped.
        // assert all update commits are present
        for (int i = 10; i < 30; i++) {
          expect(commitIdList.contains(i), true);
        }
        // assert deletes in between are skipped
        for (int i = 30; i < 39; i++) {
          expect(commitIdList.contains(i), false);
        }
        // assert last delete is present
        expect(commitIdList.contains(39), true);

        expect(syncResponseList[0]['atKey'], 'test_key_10$alice');
        expect(syncResponseList[0]['operation'], '+');
        expect(syncResponseList[0]['commitId'], 10);
        expect(syncResponseList[19]['atKey'], 'test_key_29$alice');
        expect(syncResponseList[19]['operation'], '+');
        expect(syncResponseList[19]['commitId'], 29);
        expect(syncResponseList[20]['atKey'], 'test_key_9$alice');
        expect(syncResponseList[20]['operation'], '-');
        expect(syncResponseList[20]['commitId'], 39);
      });
      test(
          'a test to verify sync response with skip deletes when commit log has less entries than default entry buffer count(25)',
          () async {
        for (int i = 0; i < 10; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 5; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }
        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '15');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        var syncResponseList = [];
        var commitIdList = [];
        for (var entry in syncResponse) {
          syncResponseList.add(entry);
          commitIdList.add(entry['commitId']);
        }

        // update commits from 5-9 should be present
        for (int i = 5; i < 10; i++) {
          expect(commitIdList.contains(i), true);
        }
        // delete commits from 10-13 should be skipped
        for (int i = 10; i < 14; i++) {
          expect(commitIdList.contains(i), false);
        }

        // last commit delete should be present
        expect(commitIdList.contains(14), true);
      });
      test(
          'a test to verify sync response with skip deletes when commit log has greater entries than default entry buffer count(25)',
          () async {
        for (int i = 0; i < 10; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 0; i < 5; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }
        for (int i = 10; i < 20; i++) {
          await putData('test_key_$i$alice');
        }
        for (int i = 10; i < 15; i++) {
          await keyValueStore.remove('test_key_$i$alice');
        }
        for (int i = 20; i < 50; i++) {
          await putData('test_key_$i$alice');
        }

        var syncProgressiveVerbHandler =
            SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(mockSocket, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '70');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);
        Map<int, String> commitIdMap = {};
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        // commit log will have
        // 5-9 updates
        // 10-14 deletes
        // 20-24 updates
        // 25-29 deletes
        // 30-59 updates
        // total entries in commit log 50
        for (int i = 5; i < 10; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        for (int i = 10; i < 15; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        for (int i = 20; i < 25; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        for (int i = 25; i < 30; i++) {
          expect(commitIdMap.containsKey(i), false);
        }
        for (int i = 30; i < 45; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
        // get the remaining updates in next sync batch
        syncVerbParams[AtConstants.fromCommitSequence] = '44';
        syncVerbParams.putIfAbsent('skipDeletesUntil', () => '70');
        response = Response();
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        syncResponse = jsonDecode(response.data!);
        for (var entry in syncResponse) {
          commitIdMap[entry['commitId']] = entry['operation'];
        }
        for (int i = 45; i < 60; i++) {
          expect(commitIdMap.containsKey(i), true);
          expect(commitIdMap[i], '+');
        }
      });

      tearDown(() async => await verbTestsTearDown());
    });
  });
}
