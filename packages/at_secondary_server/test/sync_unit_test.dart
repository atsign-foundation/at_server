import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

// How the server processes updates from the client (including the responses it generates) and what the expectations
// are - i.e. can we reject? what happens when we reject? and more
// How items are added to the commit log on the server such that they are available for sync to the clients
// How the server processes that log (when sending updates to client) - e.g. again ordering, de-duping, etc
String storageDir = '${Directory.current.path}/test/hive';
SecondaryPersistenceStore? secondaryPersistenceStore;
AtCommitLog? atCommitLog;
String atSign = '@alice';

Future<void> setUpMethod() async {
  // Initialize secondary persistent store
  secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atSign);
  // Initialize commit log
  atCommitLog = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(atSign, commitLogPath: storageDir, enableCommitId: true);
  secondaryPersistenceStore!.getSecondaryKeyStore()?.commitLog = atCommitLog;
  // Init the hive instances
  await secondaryPersistenceStore!
      .getHivePersistenceManager()!
      .init(storageDir);
  // Set currentAtSign
  AtSecondaryServerImpl.getInstance().currentAtSign = atSign;
}

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

class MockOutboundClientManager extends Mock implements OutboundClientManager {}

class MockAtCacheManager extends Mock implements AtCacheManager {}

void main() {
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
  AtCacheManager mockAtCacheManager = MockAtCacheManager();

  group(
      'A group of tests to validate how server process the updates from the client',
      () {
    group('A group of tests for various commit entry operations', () {
      setUp(() async {
        await setUpMethod();
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
        DateTime currentDateTime = DateTime.now();
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('@alice:phone@alice', AtData()..data = '123');
        // verify metadata
        AtData? atData = await secondaryPersistenceStore!
            .getSecondaryKeyStore()!
            .get('@alice:phone@alice');
        expect(
            atData!.metaData!.createdAt!
                    .difference(currentDateTime)
                    .inMilliseconds >
                1,
            true);
        expect(
            atData.metaData!.updatedAt!
                    .difference(currentDateTime)
                    .inMilliseconds >
                1,
            true);
        expect(atData.metaData!.version, 0);
        expect(atData.metaData?.createdBy, atSign);
        // verify commit entry data
        // The "getEntry" method is specific to "client" operations. Hence
        // replaced with "getEntries"
        Iterator itr = await atCommitLog!.getEntries(-1);
        itr.moveNext();
        expect(itr.current.value.operation, CommitOp.UPDATE);
        expect(itr.current.value.commitId, 0);
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
          await secondaryPersistenceStore!
              .getSecondaryKeyStore()
              ?.put('@alice:phone@alice', AtData()..data = '123');
          // Assert commit entry before update
          // The "getChanges" method is specific to the client operations. Hence
          // replaced with "getEntries" method
          Iterator itr = await atCommitLog!.getEntries(-1);
          itr.moveNext();
          expect(itr.current.value.atKey, '@alice:phone@alice');
          expect(itr.current.value.commitId, 0);
          // Update the same key again
          var keyUpdateDateTime = DateTime.now().toUtc();
          await secondaryPersistenceStore!.getSecondaryKeyStore()?.put(
              '@alice:phone@alice',
              AtData()
                ..data = '345'
                ..metaData = (AtMetaData()..ttl = 10000));
          // Assert the metadata
          AtData? atDataAfterUpdate = await secondaryPersistenceStore!
              .getSecondaryKeyStore()!
              .get('@alice:phone@alice');
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
          itr = await atCommitLog!.getEntries(-1);
          while (itr.moveNext()) {
            expect(itr.current.value.operation, CommitOp.UPDATE_ALL);
            expect(itr.current.value.commitId, 1);
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
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('@alice:phone@alice', AtData()..data = '123');
        // Updating the existing key
        var keyUpdateDateTime = DateTime.now().toUtc();
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.putMeta('@alice:phone@alice', AtMetaData()..ttl = 10000);
        // verify the metadata
        AtData? atData = await secondaryPersistenceStore!
            .getSecondaryKeyStore()!
            .get('@alice:phone@alice');
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
        AtMetaData? atMetaData = await secondaryPersistenceStore!
            .getSecondaryKeyStore()!
            .getMeta('@alice:phone@alice');
        expect(atMetaData?.commitId, 1);
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
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('@alice:phone@alice', AtData()..data = '123');
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.remove('@alice:phone@alice');
        // Verify key does not exist in the keystore
        var isKeyExist = secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.isKeyExists('@alice:phone@alice');
        expect(isKeyExist, false);
        // Verify commit entry
        Iterator itr = await atCommitLog!.getEntries(-1);
        while (itr.moveNext()) {
          expect(itr.current.value.operation, CommitOp.DELETE);
          expect(itr.current.value.commitId, 1);
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
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.remove('@alice:mobile@alice');
        // Verify key does not exist in the keystore
        var isKeyExist = secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.isKeyExists('@alice:mobile@alice');
        expect(isKeyExist, false);
        // Verify commit entry
        Iterator itr = await atCommitLog!.getEntries(-1);
        while (itr.moveNext()) {
          expect(itr.current.value.operation, CommitOp.DELETE);
          expect(itr.current.value.commitId, 0);
        }
      });
      tearDown(() async => await tearDownMethod());
    });
    group('A group of tests related to batch processing', () {
      setUp(() async => await setUpMethod());
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
            secondaryPersistenceStore!.getSecondaryKeyStore()!,
            mockOutboundClientManager,
            mockAtCacheManager,
            StatsNotificationService.getInstance(),
            NotificationManager.getInstance());
        var batchRequestCommand = jsonEncode([
          BatchRequest(100, 'update:city@alice copenhagen'),
          BatchRequest(456, 'delete:phone@alice'),
          BatchRequest(341,
              'update:dataSignature:dummy_data_signature:public:country@alice denmark'),
          BatchRequest(442,
              'update:ttl:1000:ttb:2000:ttr:3000:ccd:true:mobile@alice 1234')
        ]);
        // Process Batch request
        var batchVerbHandler = BatchVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!,
            verbHandlerManager);

        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var response = Response();
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
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
        var atData = await secondaryPersistenceStore!
            .getSecondaryKeyStore()!
            .get('city@alice');
        expect(atData!.data, 'copenhagen');
        // Assert the data and metadata stored in the keystore
        atData = await secondaryPersistenceStore!
            .getSecondaryKeyStore()!
            .get('mobile@alice');
        expect(atData!.data, '1234');
        expect(atData.metaData!.ttl, 1000);
        expect(atData.metaData!.ttb, 2000);
        expect(atData.metaData!.ttr, 3000);
        expect(atData.metaData!.isCascade, true);
        // Assert the data and metadata of a public key
        atData = await secondaryPersistenceStore!
            .getSecondaryKeyStore()!
            .get('public:country@alice');
        expect(atData!.data, 'denmark');
        expect(atData.metaData!.dataSignature, 'dummy_data_signature');
        // Assert the key is removed on delete operation
        expect(
            secondaryPersistenceStore!
                .getSecondaryKeyStore()!
                .isKeyExists('phone@alice'),
            false);
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
            secondaryPersistenceStore!.getSecondaryKeyStore()!,
            mockOutboundClientManager,
            mockAtCacheManager,
            StatsNotificationService.getInstance(),
            NotificationManager.getInstance());
        var batchRequestCommand = jsonEncode([
          BatchRequest(1, 'delete:phone@alice'),
          BatchRequest(2, 'update:city@alice'),
          BatchRequest(3, 'update:public:country@alice denmark')
        ]);
        var batchVerbHandler = BatchVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!,
            verbHandlerManager);
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var response = Response();
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
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
      tearDown(() async => await tearDownMethod());
    });
  });

  group('A group of tests to verify on server sending updates to client', () {
    group('A group of tests related to sending data to client', () {
      setUp(() async {
        await setUpMethod();
        // Setup data
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('@alice:phone.wavi@alice', AtData()..data = '8897896765');
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('public:country.wavi@alice', AtData()..data = 'Denmark');
        await secondaryPersistenceStore!.getSecondaryKeyStore()?.put(
            '@bob:file-transfer.mosphere@alice', AtData()..data = '8897896765');
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('firstName.buzz@alice', AtData()..data = 'alice');
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
        ///    commitId:1 -  public:country.wavi@alice
        ///    commitId:2 -  @bob:file-transfer.mosphere@alice
        ///    commitId:3 -  firstName.buzz@alice
        ///    commitId:4 -  @alice:phone.wavi@alice
        // Updating the key again to have two entries for the same key.
        // The entry with highest commit should be returned.
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('@alice:phone.wavi@alice', AtData()..data = '8897896766');
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponse = jsonDecode(response.data!);

        expect(syncResponse[0]['atKey'], 'public:country.wavi@alice');
        expect(syncResponse[0]['commitId'], 1);
        expect(syncResponse[0]['operation'], '+');
        expect(syncResponse[0]['metadata']['version'], '0');

        expect(syncResponse[1]['atKey'], '@bob:file-transfer.mosphere@alice');
        expect(syncResponse[1]['commitId'], 2);
        expect(syncResponse[1]['operation'], '+');
        expect(syncResponse[1]['metadata']['version'], '0');

        expect(syncResponse[2]['atKey'], 'firstname.buzz@alice');
        expect(syncResponse[2]['commitId'], 3);
        expect(syncResponse[2]['operation'], '+');
        expect(syncResponse[2]['metadata']['version'], '0');

        expect(syncResponse[3]['atKey'], '@alice:phone.wavi@alice');
        expect(syncResponse[3]['commitId'], 4);
        expect(syncResponse[3]['operation'], '*');
      });

      test(
          'test to verify only entries matching the regex are added to sync response',
          () async {
        /// Preconditions:
        /// The Commit Log Keystore contains the keys
        ///
        /// Assertions
        /// The sync response contains the keys that matches the regex in sync request
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        syncVerbParams.putIfAbsent('regex', () => 'buzz');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);

        List syncResponse = jsonDecode(response.data!);

        expect(syncResponse.length, 2);
        // As per design, all the public keys are not filtered when matching with regex.
        expect(syncResponse[0]['atKey'], 'public:country.wavi@alice');
        expect(syncResponse[0]['commitId'], 1);
        expect(syncResponse[0]['operation'], '+');
        expect(syncResponse[0]['metadata']['version'], '0');

        expect(syncResponse[1]['atKey'], 'firstname.buzz@alice');
        expect(syncResponse[1]['commitId'], 3);
        expect(syncResponse[1]['operation'], '+');
        expect(syncResponse[1]['metadata']['version'], '0');
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
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        // Setting buffer size to 250 Bytes
        syncProgressiveVerbHandler.capacity = 275;
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
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
        // The "**" in the key - @invalidkey**.buzz@alice is added to set key as invalid key
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.persistenceManager
            ?.getBox()
            .put('@invalidkey**.buzz@alice', AtData()..data = '@alice');
        AtCommitLog atCommitLog = (secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.commitLog) as AtCommitLog;
        await atCommitLog.commit('@invalidkey**.buzz@alice', CommitOp.UPDATE);

        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);

        List syncResponse = jsonDecode(response.data!);
        expect(syncResponse.length, 4);

        expect(syncResponse[0]['atKey'], "@alice:phone.wavi@alice");
        expect(syncResponse[0]['commitId'], 0);
        expect(syncResponse[0]['operation'], '+');
        expect(syncResponse[0]['metadata']['version'], '0');

        expect(syncResponse[1]['atKey'], 'public:country.wavi@alice');
        expect(syncResponse[1]['commitId'], 1);
        expect(syncResponse[1]['operation'], '+');
        expect(syncResponse[1]['metadata']['version'], '0');

        expect(syncResponse[2]['atKey'], '@bob:file-transfer.mosphere@alice');
        expect(syncResponse[2]['commitId'], 2);
        expect(syncResponse[2]['operation'], '+');
        expect(syncResponse[2]['metadata']['version'], '0');

        expect(syncResponse[3]['atKey'], 'firstname.buzz@alice');
        expect(syncResponse[3]['commitId'], 3);
        expect(syncResponse[3]['operation'], '+');
      });
      tearDown(() async => await tearDownMethod());
    });
    group('A group of test to validate the commit entry data', () {
      setUp(() async => await setUpMethod());
      test('A test to verify commit entry data when commit operation is update',
          () async {
        /// Preconditions:
        /// 1. ServerCommitId is at 2
        /// 2. The entry to sync from server is "public:phone.wavi@alice" with commitOp.Update with metadata populated
        /// 3. sync command received: sync:from:1:limit:10
        ///
        /// Operations:
        /// Run Sync verb
        ///
        /// Assertions:
        /// 1. The sync response for the key should contains following fields
        ///    "atKey": "public:phone.wavi@alice",
        ///    "commitId": 0,
        ///    "operation": "*"
        AtMetaData atMetadata = AtMetadataBuilder(
          ttl: 1000,
          ttb: 2000,
          ttr: 3000,
          ccd: true,
          dataSignature: 'dummy_data_signature',
          sharedKeyEncrypted: 'dummy_shared_key',
          publicKeyChecksum: 'dummy_checksum',
          encoding: 'base64',
          encKeyName: 'an_encrypting_key_name',
          encAlgo: 'an_encrypting_algorithm_name',
          ivNonce: 'an_iv_or_nonce',
          skeEncKeyName:
              'an_encrypting_key_name_for_the_inlined_encrypted_shared_key',
          skeEncAlgo:
              'an_encrypting_algorithm_name_for_the_inlined_encrypted_shared_key',
        ).build();
        await secondaryPersistenceStore!.getSecondaryKeyStore()?.put(
            'public:phone.wavi@alice',
            AtData()
              ..data = '8897896765'
              ..metaData = atMetadata);
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);

        // Assert the data and metadata
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi@alice');
        expect(syncResponseList[0]['commitId'], 0);
        expect(syncResponseList[0]['operation'], '*');
        expect(syncResponseList[0]['metadata']['version'], '0');
        expect(syncResponseList[0]['metadata']['ttl'], '1000');
        expect(syncResponseList[0]['metadata']['ttb'], '2000');
        expect(syncResponseList[0]['metadata']['ttr'], '3000');
        expect(syncResponseList[0]['metadata']['ccd'], 'true');
        expect(syncResponseList[0]['metadata']['dataSignature'],
            'dummy_data_signature');
        expect(syncResponseList[0]['metadata']['sharedKeyEnc'],
            'dummy_shared_key');
        expect(syncResponseList[0]['metadata']['pubKeyCS'], 'dummy_checksum');
        expect(syncResponseList[0]['metadata']['encoding'], 'base64');
        expect(syncResponseList[0]['metadata']['encKeyName'],
            'an_encrypting_key_name');
        expect(syncResponseList[0]['metadata']['encAlgo'],
            'an_encrypting_algorithm_name');
        expect(syncResponseList[0]['metadata']['ivNonce'], 'an_iv_or_nonce');
        expect(syncResponseList[0]['metadata']['skeEncKeyName'],
            'an_encrypting_key_name_for_the_inlined_encrypted_shared_key');
        expect(syncResponseList[0]['metadata']['skeEncAlgo'],
            'an_encrypting_algorithm_name_for_the_inlined_encrypted_shared_key');
      });

      test(
          'A test to verify commit entry data when commit operation is update_meta',
          () async {
        /// Preconditions:
        /// 1. ServerCommitId is at 2
        /// 2. The entry to sync from server is "public:phone.wavi@alice" with commitOp.Update
        /// 3. sync command received: sync:from:1:limit:10
        ///
        /// Operations:
        /// Run Sync verb
        ///
        /// Assertions:
        /// 1. The sync response for the key should contains following fields
        ///    "atKey": "public:phone.wavi@alice",
        ///    "metadata": <AtMetadata of the key>
        ///    "commitId": 2,
        ///    "operation": "#"
        ///    "version": 1
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('public:phone.wavi@alice', AtData()..data = '8897896765');
        // Update the metadata alone
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.putMeta('public:phone.wavi@alice', (AtMetaData()..ttl = 1000));
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi@alice');
        expect(syncResponseList[0]['value'], '8897896765');
        expect(syncResponseList[0]['operation'], '#');
        expect(syncResponseList[0]['metadata']['version'], '1');
        expect(syncResponseList[0]['metadata']['ttl'], '1000');
      });

      test('A test to verify commit entry data when commit operation is delete',
          () async {
        /// Preconditions:
        /// 1. ServerCommitId is at 2
        /// 2. The entry to sync from server is "public:phone.wavi@alice" with commitOp.Update
        /// 3. sync command received: sync:from:1:limit:10
        ///
        /// Operations:
        /// Run Sync verb
        ///
        /// Assertions:
        /// 1. The sync response for the key should contains following fields
        ///    "atKey": "public:phone.wavi@alice",
        ///    "commitId": 2,
        ///    "operation": "-"
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('public:phone.wavi@alice', AtData()..data = '8897896765');
        // Delete the key
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.remove('public:phone.wavi@alice');
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi@alice');
        expect(syncResponseList[0]['operation'], '-');
      });
      tearDown(() async => await tearDownMethod());
    });

    group('A group of tests on TTL and TTB with respect to sync', () {
      setUp(() async => await setUpMethod());
      test(
          'test to verify when TTL of a key is expired and deleted then commit operation should have delete',
          () async {
        /// Preconditions:
        /// 1. The key is created on server at time T1 with TTL set
        /// 2. The key is expired at time T2 (T2 > T1); and key is deleted from keystore
        /// 3. The sync triggers at time T3 (T3 > T2)
        /// 4. The key is deleted and commitLog should have a commitOp.delete
        ///
        /// Assertions:
        /// 1. The sync response should contain the commit entry of commitOp.delete
        await secondaryPersistenceStore!.getSecondaryKeyStore()?.put(
            'public:lastname.wavi@alice',
            AtData()
              ..data = '8897896765'
              ..metaData = (AtMetaData()..ttl = 1));
        // manually trigger the deleteExpiredKeys to remove the expired keys
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.deleteExpiredKeys();
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList[0]['atKey'], 'public:lastname.wavi@alice');
        expect(syncResponseList[0]['operation'], '-');
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
        await secondaryPersistenceStore!.getSecondaryKeyStore()?.put(
            'public:phone.wavi@alice',
            AtData()
              ..data = '8897896765'
              ..metaData =
                  (AtMetaData()..ttb = Duration(minutes: 1).inMilliseconds));
        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi@alice');
        expect(syncResponseList[0]['value'], '8897896765');
        expect(syncResponseList[0]['operation'], '*');
      });
      tearDown(() async => await tearDownMethod());
    });

    group('A group of tests on APKAM Enrollment', () {
      setUp(() async => await setUpMethod());
      test(
          'A test to verify keys whose namespace are enrolled are only returned',
          () async {
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('public:phone.wavi@alice', AtData()..data = '8897896765');
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('public:mobile.buzz@alice', AtData()..data = '8897896765');
        var enrollmentId = Uuid().v4();
        String enrollmentKey =
            '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace@alice';
        final enrollJson = {
          'sessionId': '123',
          'appName': 'wavi',
          'deviceName': 'pixel',
          'namespaces': {'wavi': 'rw'},
          'apkamPublicKey': 'testPublicKeyValue',
          'requestType': 'newEnrollment',
          'approval': {'state': 'approved'}
        };
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put(enrollmentKey, AtData()..data = jsonEncode(enrollJson));

        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        (atConnection.metaData as InboundConnectionMetadata).enrollmentId =
            enrollmentId;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList.length, 1);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi@alice');
        expect(syncResponseList[0]['operation'], '+');
      });

      test(
          'A test to verify all keys are returned when enrollment contains *:rw',
          () async {
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('public:phone.wavi@alice', AtData()..data = '8897896765');
        await secondaryPersistenceStore!
            .getSecondaryKeyStore()
            ?.put('public:mobile.buzz@alice', AtData()..data = '8897896765');
        var enrollmentId = Uuid().v4();
        String enrollmentKey =
            '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace@alice';
        final enrollJson = {
          'sessionId': '123',
          'appName': 'wavi',
          'deviceName': 'pixel',
          'namespaces': {'wavi': 'rw', '*': 'rw'},
          'apkamPublicKey': 'testPublicKeyValue',
          'requestType': 'newEnrollment',
          'approval': {'state': 'approved'}
        };
        await secondaryPersistenceStore!.getSecondaryKeyStore()?.put(
            enrollmentKey, AtData()..data = jsonEncode(enrollJson),
            skipCommit: true);

        var syncProgressiveVerbHandler = SyncProgressiveVerbHandler(
            secondaryPersistenceStore!.getSecondaryKeyStore()!);
        var response = Response();
        var inBoundSessionId = '_6665436c-29ff-481b-8dc6-129e89199718';
        var atConnection = InboundConnectionImpl(null, inBoundSessionId);
        atConnection.metaData.isAuthenticated = true;
        (atConnection.metaData as InboundConnectionMetadata).enrollmentId =
            enrollmentId;
        var syncVerbParams = HashMap<String, String>();
        syncVerbParams.putIfAbsent(AtConstants.fromCommitSequence, () => '-1');
        await syncProgressiveVerbHandler.processVerb(
            response, syncVerbParams, atConnection);
        List syncResponseList = jsonDecode(response.data!);
        expect(syncResponseList.length, 2);
        expect(syncResponseList[0]['atKey'], 'public:phone.wavi@alice');
        expect(syncResponseList[0]['operation'], '+');
        expect(syncResponseList[1]['atKey'], 'public:mobile.buzz@alice');
        expect(syncResponseList[1]['operation'], '+');
      });
      tearDown(() async => await tearDownMethod());
    });
  });
}

Future<void> tearDownMethod() async {
  await SecondaryPersistenceStoreFactory.getInstance().close();
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory(storageDir).exists();
  if (isExists) {
    Directory(storageDir).deleteSync(recursive: true);
  }
}
