import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  group('A group of hive keystore impl tests', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test('test update', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      var result = await keyStore.create('phone.wavi@test_user_1', atData);
      expect(result, isNotNull);
    });

    test('test create and get', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await keyStore.create('phone.wavi@test_user_1', atData);
      var dataFromHive = await (keyStore.get('phone.wavi@test_user_1'));
      expect(dataFromHive?.data, '123');
    });

    test('test create, update and get', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;

      var key = 'location.wavi@test_user_1';

      var atData = AtData();
      atData.data = 'india';
      await keyStore.create(key, atData);

      var dataFromHive = await (keyStore.get(key));
      expect(dataFromHive?.data, 'india');

      var updateData = AtData();
      updateData.data = 'united states';
      await keyStore.put(key, updateData);

      dataFromHive = await (keyStore.get(key));
      expect(dataFromHive?.data, 'united states');
    });

    test('test create, update and get with metadata', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;

      var key = 'location.wavi@test_user_1';

      for (int i = 0; i < 50; i++) {
        var atData = AtData();
        atData.data = 'india';
        var commonsMetadata = Metadata()
          ..ttl = 100
          ..ttb = 200
          ..ttr = 3600
          ..ccd = true
          ..isBinary = false
          ..isEncrypted = true
          ..dataSignature = 'dataSignature'
          ..pubKeyCS = 'pubKeyChecksum'
          ..sharedKeyEnc = 'sharedKeyEncrypted'
          ..encoding = 'someEncoding'
          ..encKeyName = 'someEncKeyName'
          ..encAlgo = 'AES/CTR/PKCS7Padding'
          ..ivNonce = 'someIvNonce'
          ..skeEncKeyName = 'someSkeEncKeyName'
          ..skeEncAlgo = 'someSkeEncAlgo';
        var atMetaData = AtMetaData.fromCommonsMetadata(commonsMetadata);
        atData.metaData = atMetaData;
        await keyStore.create(key, atData);

        var dataFromHive = await (keyStore.get(key));
        expect(dataFromHive?.data, 'india');
        expect(dataFromHive?.metaData, atMetaData);

        var updateData = AtData();
        var updateMetaData =
            AtMetaData.fromJson(atMetaData.toJson()); // clone it
        updateData.data = 'united states';
        updateData.metaData = updateMetaData;
        await keyStore.put(key, updateData);

        dataFromHive = await (keyStore.get(key));
        expect(dataFromHive?.data, 'united states');
        expect(dataFromHive?.metaData, updateMetaData);

        updateMetaData.skeEncKeyName = 'someOtherEncKeyName';
        updateMetaData.skeEncAlgo = 'someOtherEncAlgo';
        await keyStore.put(key, updateData);

        dataFromHive = await (keyStore.get(key));
        expect(dataFromHive?.data, 'united states');
        expect(dataFromHive?.metaData, updateMetaData);
      }
    });

    test('test update and get', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var updateData = AtData();
      updateData.data = 'alice';
      await keyStore.put('last_name.wavi@test_user_1', updateData);
      var dataFromHive = await (keyStore.get('last_name.wavi@test_user_1'));
      expect(dataFromHive?.data, 'alice');
    });

    test('test update and remove', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var updateData = AtData();
      updateData.data = 'alice';
      await keyStore.put('last_name.wavi@test_user_1', updateData);
      await keyStore.remove('last_name.wavi@test_user_1');
      expect(() => keyStore.get('last_name.wavi@test_user_1'),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
    });

    test('get keys', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var data_1 = AtData();
      data_1.data = 'alice';
      await keyStore.put('last_name.wavi@test_user_1', data_1);
      var data_2 = AtData();
      data_2.data = 'bob';
      await keyStore.put('first_name.wavi@test_user_1', data_2);
      var keys = keyStore.getKeys();
      expect(keys.length, 2);
    });

    test('test get expired keys - no data', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager!.getSecondaryKeyStore();
      var expiredKeys = await keyStore!.getExpiredKeys();
      expect(expiredKeys.length, 0);
    });

    // test('test hive files deleted - get - box not available', () async {
    //   var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
    //       .getSecondaryPersistenceStore('@test_user_1')!;
    //   var keyStore = keyStoreManager.getSecondaryKeyStore();
    //   await Hive.deleteBoxFromDisk(_getShaForAtsign('@test_user_1'));
    //   expect(
    //       () async => await keyStore!.get('abc'),
    //       throwsA(predicate((dynamic e) =>
    //           e is DataStoreException &&
    //           e.message == 'Box has already been closed.')));
    // });
    //
    // test('test hive files deleted - put - box not available', () async {
    //   var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
    //       .getSecondaryPersistenceStore('@test_user_1')!;
    //   var keyStore = keyStoreManager.getSecondaryKeyStore();
    //   await Hive.deleteBoxFromDisk(_getShaForAtsign('@test_user_1'));
    //   expect(
    //       () async => await keyStore!.put('abc', null),
    //       throwsA(predicate((dynamic e) =>
    //           e is DataStoreException &&
    //           e.message == 'Box has already been closed.')));
    // });

    test('test delete expired keys - no data', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager!.getSecondaryKeyStore();
      var result = await keyStore!.deleteExpiredKeys();
      expect(result, true);
    });

    test('get keys by regex', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var data_1 = AtData();
      data_1.data = 'alice';
      await keyStore.put('last_name.wavi@test_user_1', data_1);
      var data_2 = AtData();
      data_2.data = 'bob';
      await keyStore.put('first_name.wavi@test_user_1', data_2);
      var keys = keyStore.getKeys(regex: '^first');
      expect(keys.length, 1);
    });

    test('test create and get for metadata-ttl', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await keyStore.create('phone.wavi@test_user_1', atData,
          time_to_live: 6000);
      var dataFromHive = await (keyStore.get('phone.wavi@test_user_1'));
      expect(dataFromHive?.data, '123');
      expect(dataFromHive?.metaData, isNotNull);
      expect(dataFromHive?.metaData!.ttl, 6000);
    });

    test('test create and get for metadata-shared key', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await keyStore.create('phone.wavi@test_user_1', atData,
          sharedKeyEncrypted: 'abc', publicKeyChecksum: 'xyz');
      var dataFromHive = await (keyStore.get('phone.wavi@test_user_1'));
      expect(dataFromHive?.data, '123');
      expect(dataFromHive?.metaData, isNotNull);
      expect(dataFromHive?.metaData!.sharedKeyEnc, 'abc');
      expect(dataFromHive?.metaData!.pubKeyCS, 'xyz');
    });

    test('test create reserved key- keystore put', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      final result = await keyStore.put(AT_PKAM_PRIVATE_KEY, atData);
      expect(result, isA<int>());
    });

    test('test create non reserved key- keystore put', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyStore.put('privatekey:mykey', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test create invalid key', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyStore.create('hello123', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test put invalid key', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyStore.put('hello@', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test create non reserved key- keystore putAll', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyStore.put('privatekey:mykey', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test putAll invalid key', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyStore.put('hello@', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });
    tearDown(() async => await tearDownFunc(atSign));
  });

  group('A group of tests to verify compaction', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));

    test('test to verify commit log compaction', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var commitLogInstance = await (AtCommitLogManagerImpl.getInstance()
          .getCommitLog('@test_user_1'));
      var compactionService =
          CommitLogCompactionService(commitLogInstance!.commitLogKeyStore);
      commitLogInstance.addEventListener(compactionService);
      var atData = AtData()..data = 'US';
      //
      for (int i = 0; i <= 49; i++) {
        await keyStore.put('@bob:location.wavi@test_user_1', atData);
      }
      var locationList =
          compactionService.getEntries('@bob:location.wavi@test_user_1');
      expect(locationList?.getSize(), 1);
      await keyStore.put('@bob:location.wavi@test_user_1', atData);
      expect(locationList?.getSize(), 1);
    }, skip: 'Commit log compaction service is removed');
    tearDown(() async => await tearDownFunc(atSign));
  });

  group('A group of tests to verify expiryKeysCache', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test(
        'A test to verify key updated via put method without TTL and TTB is not added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_create_1'
        ..metaData = (AtMetaData()..isEncrypted = false);
      await keystore?.put('sample_create_key_1.wavi@test_user_1', atData);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache!.containsKey('sample_create_key_1.wavi@test_user_1'),
          false);
    });

    test(
        'A test to verify key updated via put method with TTL is added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_create_1'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttl = 1000);
      await keystore?.put('sample_create_key_1🛠.wavi@test_user_1', atData);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(
          metaDataCache!.containsKey('sample_create_key_1🛠.wavi@test_user_1'),
          true);
    });

    test(
        'A test to verify key updated via put method with TTB is added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_create_1'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttb = 1000);
      await keystore?.put('sample_create_key_1🛠.wavi@test_user_1', atData);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(
          metaDataCache!.containsKey('sample_create_key_1🛠.wavi@test_user_1'),
          true);
    });

    test(
        'A test to verify key created via create method without TTL and TTB is not added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_put_1'
        ..metaData = (AtMetaData()..isEncrypted = false);
      final testKey = 'sample_data_put_1.wavi@test_user_1';
      await keystore?.create(testKey, atData);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache!.containsKey(testKey), false);
    });

    test(
        'A test to verify key created via create method with TTL is added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_put_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttl = 10000);
      final testKey = 'sample_put_key_2🛠.wavi@test_user_1';
      await keystore?.create(testKey, atData);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache!.containsKey(testKey), true);
    });

    test(
        'A test to verify key created via create method with TTB is added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_put_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttb = 10000);
      final testKey = 'sample_put_key_2🛠.wavi@test_user_1';
      await keystore?.create(testKey, atData);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache!.containsKey(testKey), true);
    });

    test(
        'A test to verify key created via create method with TTB and TTL is added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_put_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttl = 10000
          ..ttb = 10000);
      final testKey = 'sample_put_key_2🛠.wavi@test_user_1';
      await keystore?.create(testKey, atData);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache!.containsKey(testKey), true);
    });

    test('A test to verify deleted key is removed from metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_remove_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = true
          ..ttl = 10000);
      final testKey = 'sample_remove_key_2🛠.wavi@test_user_1';
      await keystore?.put(testKey, atData);
      final int? cacheEntriesCountBeforeRemove =
          keystore?.getExpiryKeysCache().length;
      final removeResult = await keystore?.remove(testKey);
      expect(removeResult, isNotNull);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache!.length, cacheEntriesCountBeforeRemove! - 1);
      expect(metaDataCache.containsKey(testKey), false);
    });

    test(
        'A test to verify deleting a key which is not present in metaDataCache does not raise exception',
        () async {
      String atSign = '@test_user_1';
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(atSign);
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data_remove_4'
        ..metaData = (AtMetaData()..isEncrypted = false);
      final testKey = 'non_existent_key.wavi$atSign';
      await keystore?.put(testKey, atData);
      await keystore?.remove(testKey);
    });

    test('A test to verify metaDataCache with put and remove operations',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'value_test_1'
        ..metaData = (AtMetaData()..ttl = 10000);
      // The key will be inserted into metadata cache
      await keystore?.put('key_test_1.wavi@test_user_1', atData);
      AtMetaData? getMetaResult =
          await keystore?.getMeta('key_test_1.wavi@test_user_1');
      expect(getMetaResult?.ttl, 10000);
      await keystore?.remove('key_test_1.wavi@test_user_1');
      expect(await keystore?.getMeta('key_test_1.wavi@test_user_1'), null);
    });

    test(
        'A test to verify key updated via putMeta method is added to metaDataCache',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'value_test_2'
        ..metaData = (AtMetaData()..ttl = 10000);
      await keystore?.put('key_test_2.wavi@test_user_1', atData);
      await keystore?.putMeta(
          'key_test_2.wavi@test_user_1', AtMetaData()..ttl = 300000);
      AtMetaData? newMeta =
          await keystore?.getMeta('key_test_2.wavi@test_user_1');
      expect(newMeta?.ttl, 300000);
    });

    test('A test to verify metaDataCache with sequence of put operation',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'dummy_data'
        ..metaData = (AtMetaData()
          ..ttl = 1000
          ..ttb = 10000);
      for (int i = 1; i <= 5; i++) {
        final testKey = 'sample_data_put_$i.wavi@test_user_1';
        atData.data = 'sample_data_put_$i';
        await keystore?.create(testKey, atData);
      }
      final metaDataCache = keystore?.getExpiryKeysCache();
      for (int i = 1; i <= 5; i++) {
        final testKey = 'sample_data_put_$i.wavi@test_user_1';
        atData.data = 'sample_data_put_$i';
        expect(keystore?.isKeyExists(testKey), true);
        expect(metaDataCache?.containsKey(testKey), true);
      }
    });

    test(
        'test random sequence of put operations and delete operation - check cache and keystore entries',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'sample_data'
        ..metaData = (AtMetaData()..ttl = 10000);
      // put 3 keys
      final testKey_1 = 'sample_data_put_1.wavi@test_user_1';
      await keystore?.create(testKey_1, atData);
      final testKey_2 = 'sample_data_put_2.wavi@test_user_1';
      await keystore?.create(testKey_2, atData);
      final testKey_3 = 'sample_data_put_3.wavi@test_user_1';
      await keystore?.create(testKey_3, atData);

      // delete 2 keys
      await keystore?.remove(testKey_3);
      await keystore?.remove(testKey_2);
      final metaDataCache = keystore?.getExpiryKeysCache();
      expect(keystore?.isKeyExists(testKey_1), true);
      expect(metaDataCache?.containsKey(testKey_1), true);
      expect(keystore?.isKeyExists(testKey_2), false);
      expect(metaDataCache?.containsKey(testKey_2), false);
      expect(keystore?.isKeyExists(testKey_3), false);
      expect(metaDataCache?.containsKey(testKey_3), false);
    });

    test('A test to verify new metadata is returned when TTL is unset',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'dummy_value'
        ..metaData = (AtMetaData()..ttl = 10000);
      await keystore?.put('dummykey.wavi@test_user_1', atData);
      AtData updatedAtData = AtData()
        ..data = 'updated_value'
        ..metaData = (AtMetaData()
          ..ttl = 0
          ..ttr = -1);
      await keystore?.put('dummykey.wavi@test_user_1', updatedAtData,
          time_to_born: null);
      AtMetaData? atMetaData =
          await keystore?.getMeta('dummykey.wavi@test_user_1');
      expect(atMetaData?.ttr, -1);
      expect(atMetaData?.ttl, 0);
    });

    test(
        'A test to verify getExpiredKeys method returns the keys whose TTL is met eventually',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'dummy_value'
        ..metaData = (AtMetaData()..ttl = 1500);
      await keystore?.put('keyabouttoexpire.wavi@test_user_1', atData);
      var expiredKeysList = await keystore?.getExpiredKeys();
      expect(expiredKeysList?.contains('keyabouttoexpire.wavi@test_user_1'),
          false);
      await Future.delayed(Duration(milliseconds: 1700));
      expiredKeysList = await keystore?.getExpiredKeys();
      expect(
          expiredKeysList?.contains('keyabouttoexpire.wavi@test_user_1'), true);
    });
    tearDown(() async => await tearDownFunc(atSign));
  });

  group('A group of test related to getKeys method', () {
    String atSign = '@emoji🛠️';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test('A test to verify getKeys does not return expired keys', () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(atSign);
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'value_test_4'
        // Adding TTL of 10 milliseconds
        ..metaData = (AtMetaData()..ttl = 10);
      await keystore?.put('expired_key.wavi$atSign', atData);
      // Adding delay for the key to expire.
      await Future.delayed(Duration(milliseconds: 20));
      List<String>? keysList = keystore?.getKeys();
      expect(keysList!.contains('expired_key.wavi$atSign'), false);
    });

    test('A test to verify getKeys does not return keys whose TTB is met',
        () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(atSign);
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData()..ttb = 300000);
      await keystore?.put('key_test_3.wavi$atSign', atData);
      List<String>? keysList = keystore?.getKeys();
      expect(keysList!.contains('key_test_3.wavi$atSign'), false);
    });

    test('test to verify metadata of all keys is cached', () async {
      SecondaryPersistenceStore? keystoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore(atSign);
      HiveKeystore? keystore = keystoreManager?.getSecondaryKeyStore();
      AtData? atData = AtData();
      AtMetaData? metaData;
      //inserting sample keys
      for (int i = 0; i < 30; i++) {
        //inserting random metaData to induce variance in data
        metaData = AtMetadataBuilder(
                ttl: 12000 + i.toInt(),
                ttb: i,
                atSign: '@atsign_$i',
                isBinary: true)
            .build();

        atData.data = 'value_test_$i';
        atData.metaData = metaData;
        await keystore?.put('key_test_$i.wavi$atSign', atData);
      }

      List<String>? keys = keystore?.getKeys();

      for (var key in keys!) {
        atData = await keystore?.get(key);
        metaData = atData?.metaData;
        expect((await keystore?.getMeta(key)).toString(), metaData.toString());
      }
    });

    test('A test to verify getKeys return key with emoji', () async {
      HiveKeystore? keystore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)
          ?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData());
      await keystore?.put('emoji_🛠️.wavi$atSign', atData);
      List<String>? keysList = keystore?.getKeys();
      print(keysList);
      expect(keysList?.contains('emoji_🛠️.wavi$atSign'), true);
    });

    test('A test to verify getKeys returns key with emoji when TTB is set',
        () async {
      HiveKeystore? keystore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)
          ?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData()..ttb = 1000);
      await keystore?.put('emoji_🛠️.wavi$atSign', atData);
      List<String>? keysList = keystore?.getKeys();
      expect(keysList?.contains('emoji_🛠️.wavi$atSign'), false);
      await Future.delayed(Duration(milliseconds: 1000));
      keysList = keystore?.getKeys();
      expect(keysList?.contains('emoji_🛠️.wavi$atSign'), true);
    });

    test(
        'A test to verify getKeys does not return key with emoji when TTL is set',
        () async {
      HiveKeystore? keystore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)
          ?.getSecondaryKeyStore();
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData()..ttl = 1000);
      await keystore?.put('emoji_🛠️.wavi$atSign', atData);
      List<String>? keysList = keystore?.getKeys();
      expect(keysList?.contains('emoji_🛠️.wavi$atSign'), true);
      await Future.delayed(Duration(milliseconds: 1000));
      keysList = keystore?.getKeys();
      expect(keysList?.contains('emoji_🛠️.wavi$atSign'), false);
    });

    tearDown(() async => await tearDownFunc(atSign));
  });

  group('A group of tests to verify skip commit', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test('skip commit true in put', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      var result = await keyStore.put('phone.wavi@test_user_1', atData,
          skipCommit: true);
      expect(result, -1);
      // var commitLogInstance = await (AtCommitLogManagerImpl.getInstance()
      //     .getCommitLog('@test_user_1'));
      // var commitId = await commitLogInstance!
      //     .getLatestCommitEntry('phone.wavi@test_user_1');
      // expect(commitId, isNull);
    });
    test('skip commit true in create', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      var result = await keyStore.create('email.wavi@test_user_1', atData,
          skipCommit: true);
      expect(result, -1);
      // var commitLogInstance = await (AtCommitLogManagerImpl.getInstance()
      //     .getCommitLog('@test_user_1'));
      // expect(
      //     (await commitLogInstance!
      //         .getLatestCommitEntry('email.wavi@test_user_1')),
      //     isNull);
    });
    test('skip commit true in remove', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      var result =
          await keyStore.remove('firstname.wavi@test_user_1', skipCommit: true);
      expect(result, -1);
      // var commitLogInstance = await (AtCommitLogManagerImpl.getInstance()
      //     .getCommitLog('@test_user_1'));
      // expect(
      //     (await commitLogInstance!
      //         .getLatestCommitEntry('firstname.wavi@test_user_1')),
      //     isNull);
    });
    tearDown(() async => await tearDownFunc(atSign));
  });
}

Future<void> tearDownFunc(String atSign) async {
  await Hive.deleteBoxFromDisk('commit_log_$atSign');
  await Hive.deleteBoxFromDisk(_getShaForAtSign(atSign));
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}

Future<void> setUpFunc(String storageDir, String atSign) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog(atSign, commitLogPath: storageDir);
  var persistenceManager = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(atSign)!;
  await persistenceManager.getHivePersistenceManager()!.init(storageDir);

  AtKeyServerMetadataStoreImpl atKeyMetadataStoreImpl =
      AtKeyServerMetadataStoreImpl(atSign);
  await atKeyMetadataStoreImpl.init(storageDir);

  persistenceManager.getSecondaryKeyStore()!.commitLog = commitLogInstance;
  (persistenceManager.getSecondaryKeyStore()!.commitLog as AtCommitLog)
      .commitLogKeyStore
      .atKeyMetadataStore = atKeyMetadataStoreImpl;
}

String _getShaForAtSign(String atSign) {
  var bytes = utf8.encode(atSign);
  return sha256.convert(bytes).toString();
}
