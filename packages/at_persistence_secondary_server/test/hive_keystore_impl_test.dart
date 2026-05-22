import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  group('A group of hive keystore impl tests', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test('test update', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var result = await keyValueStore.create('phone.wavi@test_user_1', atData);
      expect(result, isNotNull);
    });

    test('test create and get', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      await keyValueStore.create('phone.wavi@test_user_1', atData);
      var dataFromHive = await (keyValueStore.get('phone.wavi@test_user_1'));
      expect(dataFromHive?.data, '123');
    });

    test('test create, update and get', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');

      var key = 'location.wavi@test_user_1';

      var atData = AtData();
      atData.data = 'india';
      await keyValueStore.create(key, atData);

      var dataFromHive = await (keyValueStore.get(key));
      expect(dataFromHive?.data, 'india');

      var updateData = AtData();
      updateData.data = 'united states';
      await keyValueStore.put(key, updateData);

      dataFromHive = await (keyValueStore.get(key));
      expect(dataFromHive?.data, 'united states');
    });

    test('test create, update and get with metadata', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');

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
          ..skeEncAlgo = 'someSkeEncAlgo'
          ..pubKeyHash = PublicKeyHash('someHashValue', 'sha512');
        var atMetaData =
            AtMetaData.fromCommonsMetadata(commonsMetadata, '@test_user_1');
        atData.metaData = atMetaData;
        await keyValueStore.create(key, atData);

        var dataFromHive = await (keyValueStore.get(key));
        expect(dataFromHive?.data, 'india');
        expect(dataFromHive?.metaData, atMetaData);
        expect(dataFromHive?.metaData?.pubKeyHash?.hash, 'someHashValue');
        expect(dataFromHive?.metaData?.pubKeyHash?.hashingAlgo, 'sha512');

        var updateData = AtData();
        var updateMetaData =
            AtMetaData.fromJson(atMetaData.toJson()); // clone it
        updateData.data = 'united states';
        updateData.metaData = updateMetaData;
        await keyValueStore.put(key, updateData);

        dataFromHive = await (keyValueStore.get(key));
        expect(dataFromHive?.data, 'united states');
        expect(dataFromHive?.metaData, updateMetaData);

        updateMetaData.skeEncKeyName = 'someOtherEncKeyName';
        updateMetaData.skeEncAlgo = 'someOtherEncAlgo';
        await keyValueStore.put(key, updateData);

        dataFromHive = await (keyValueStore.get(key));
        expect(dataFromHive?.data, 'united states');
        expect(dataFromHive?.metaData, updateMetaData);
      }
    });

    test('test update and get', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var updateData = AtData();
      updateData.data = 'alice';
      await keyValueStore.put('last_name.wavi@test_user_1', updateData);
      var dataFromHive =
          await (keyValueStore.get('last_name.wavi@test_user_1'));
      expect(dataFromHive?.data, 'alice');
    });

    test('test update and remove', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var updateData = AtData();
      updateData.data = 'alice';
      await keyValueStore.put('last_name.wavi@test_user_1', updateData);
      await keyValueStore.remove('last_name.wavi@test_user_1');
      expect(() => keyValueStore.get('last_name.wavi@test_user_1'),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
    });

    test('get keys', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var data_1 = AtData();
      data_1.data = 'alice';
      await keyValueStore.put('last_name.wavi@test_user_1', data_1);
      var data_2 = AtData();
      data_2.data = 'bob';
      await keyValueStore.put('first_name.wavi@test_user_1', data_2);
      var keys = (await (await keyValueStore.getKeys()).toList());
      expect(keys.length, 2);
    });

    test('test get expired keys - no data', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var expiredKeys = await (await keyValueStore.getExpiredKeys()).toList();
      expect(expiredKeys.length, 0);
    });

    // test('test hive files deleted - get - box not available', () async {
    //   var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
    //       .getSecondaryPersistenceStore('@test_user_1')!;
    //   var keyValueStore = keyStoreManager.getAtKeyValueStore();
    //   await Hive.deleteBoxFromDisk(_getShaForAtsign('@test_user_1'));
    //   expect(
    //       () async => await keyValueStore!.get('abc'),
    //       throwsA(predicate((dynamic e) =>
    //           e is DataStoreException &&
    //           e.message == 'Box has already been closed.')));
    // });
    //
    // test('test hive files deleted - put - box not available', () async {
    //   var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
    //       .getSecondaryPersistenceStore('@test_user_1')!;
    //   var keyValueStore = keyStoreManager.getAtKeyValueStore();
    //   await Hive.deleteBoxFromDisk(_getShaForAtsign('@test_user_1'));
    //   expect(
    //       () async => await keyValueStore!.put('abc', null),
    //       throwsA(predicate((dynamic e) =>
    //           e is DataStoreException &&
    //           e.message == 'Box has already been closed.')));
    // });

    test('test delete expired keys - no data', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var result = await keyValueStore.deleteExpiredKeys();
      expect(result, true);
    });

    test('get keys by regex', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var data_1 = AtData();
      data_1.data = 'alice';
      await keyValueStore.put('last_name.wavi@test_user_1', data_1);
      var data_2 = AtData();
      data_2.data = 'bob';
      await keyValueStore.put('first_name.wavi@test_user_1', data_2);
      var keys =
          (await (await keyValueStore.getKeys(regex: '^first')).toList());
      expect(keys.length, 1);
    });

    test('test create and get for metadata-ttl', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      atData.metaData = AtMetaData()..ttl = 6000;
      await keyValueStore.create('phone.wavi@test_user_1', atData);
      var dataFromHive = await (keyValueStore.get('phone.wavi@test_user_1'));
      expect(dataFromHive?.data, '123');
      expect(dataFromHive?.metaData, isNotNull);
      expect(dataFromHive?.metaData!.ttl, 6000);
    });

    test('test create and get for metadata-shared key', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      atData.metaData = AtMetaData()
        ..sharedKeyEnc = 'abc'
        ..pubKeyCS = 'xyz';
      await keyValueStore.create('phone.wavi@test_user_1', atData);
      var dataFromHive = await (keyValueStore.get('phone.wavi@test_user_1'));
      expect(dataFromHive?.data, '123');
      expect(dataFromHive?.metaData, isNotNull);
      expect(dataFromHive?.metaData!.sharedKeyEnc, 'abc');
      expect(dataFromHive?.metaData!.pubKeyCS, 'xyz');
    });

    test('test create reserved key- keystore put', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      final result =
          await keyValueStore.put(AtConstants.atPkamPrivateKey, atData);
      expect(result, isA<int>());
    });

    test('test create non reserved key- keystore put', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyValueStore.put('privatekey:mykey', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test create invalid key', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyValueStore.create('hello123', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test put invalid key', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyValueStore.put('hello@', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test create non reserved key- keystore putAll', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyValueStore.put('privatekey:mykey', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test putAll invalid key', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      await expectLater(keyValueStore.put('hello@', atData),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test put max key length exceeded', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var key = '${TestUtils.generateRandomString(245)}@test_user_1';
      await expectLater(
          keyValueStore.put(key, atData),
          throwsA(predicate((dynamic e) =>
              e is DataStoreException &&
              e.message ==
                  "key length ${key.length} is greater than max allowed ${HiveAtKeyValueStore.maxKeyLengthWithoutCached} chars")));
      var cachedKey =
          'cached:public:${TestUtils.generateRandomString(245)}@test_user_1';
      await expectLater(
          keyValueStore.put(cachedKey, atData),
          throwsA(predicate((dynamic e) =>
              e is DataStoreException &&
              e.message ==
                  "key length ${cachedKey.length} is greater than max allowed ${HiveAtKeyValueStore.maxKeyLength} chars")));
    });
    test('test put key length 248 chars should pass', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var key = '${TestUtils.generateRandomString(236)}@test_user_1';
      var result = await keyValueStore.put(key, atData);
      expect(result! >= 0, true);
    });
    tearDown(() async => await tearDownFunc(atSign));

    test('test create max key length exceeded', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var key = '${TestUtils.generateRandomString(245)}@test_user_1';
      await expectLater(
          keyValueStore.create(key, atData),
          throwsA(predicate((dynamic e) =>
              e is DataStoreException &&
              e.message ==
                  "key length ${key.length} is greater than max allowed ${HiveAtKeyValueStore.maxKeyLengthWithoutCached} chars")));
      var cachedKey =
          'cached:public:${TestUtils.generateRandomString(250)}@test_user_1';
      await expectLater(
          keyValueStore.create(cachedKey, atData),
          throwsA(predicate((dynamic e) =>
              e is DataStoreException &&
              e.message ==
                  "key length ${cachedKey.length} is greater than max allowed ${HiveAtKeyValueStore.maxKeyLength} chars")));
    });
    test('test create key length 248 chars should pass', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var key = '${TestUtils.generateRandomString(236)}@test_user_1';
      var result = await keyValueStore.create(key, atData);
      expect(result! >= 0, true);
    });
    test('test putAll max key length exceeded', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var key = '${TestUtils.generateRandomString(250)}@test_user_1';
      await expectLater(
          keyValueStore.putAll(key, atData, AtMetaData()),
          throwsA(predicate((dynamic e) =>
              e is DataStoreException &&
              e.message ==
                  "key length ${key.length} is greater than max allowed ${HiveAtKeyValueStore.maxKeyLengthWithoutCached} chars")));
      var cachedKey =
          'cached:public:${TestUtils.generateRandomString(270)}@test_user_1';
      await expectLater(
          keyValueStore.putAll(cachedKey, atData, AtMetaData()),
          throwsA(predicate((dynamic e) =>
              e is DataStoreException &&
              e.message ==
                  "key length ${cachedKey.length} is greater than max allowed ${HiveAtKeyValueStore.maxKeyLength} chars")));
    });
    test('test putAll key length 248 chars should pass', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var key = '${TestUtils.generateRandomString(236)}@test_user_1';
      var result = await keyValueStore.putAll(key, atData, AtMetaData());
      expect(result, isNotNull);
      expect(result! >= 0, true);
    });
    tearDown(() async => await tearDownFunc(atSign));
  });

  group('A group of tests to verify the one-entry-per-atKey invariant', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test('Box has exactly 1 entry after 50 puts to the same atKey', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var commitLogInstance = (await testCommitLogFor('@test_user_1'));
      var atData = AtData()..data = 'US';
      for (int i = 0; i <= 49; i++) {
        await keyValueStore.put('@bob:location.wavi@test_user_1', atData);
      }
      expect(commitLogInstance.commitLogKeyStore.getEntriesCount(), 1);
    });
    tearDown(() async => await tearDownFunc(atSign));
  });

  group('A group of tests to verify expiryKeysCache', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test(
        'A test to verify key updated via put method without TTL and TTB is not added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_create_1'
        ..metaData = (AtMetaData()..isEncrypted = false);
      await keystore.put('sample_create_key_1.wavi@test_user_1', atData);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache.containsKey('sample_create_key_1.wavi@test_user_1'),
          false);
    });

    test(
        'A test to verify key updated via put method with TTL is added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_create_1'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttl = 1000);
      await keystore.put('sample_create_key_1🛠.wavi@test_user_1', atData);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(
          metaDataCache.containsKey('sample_create_key_1🛠.wavi@test_user_1'),
          true);
    });

    test(
        'A test to verify key updated via put method with TTB is added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_create_1'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttb = 1000);
      await keystore.put('sample_create_key_1🛠.wavi@test_user_1', atData);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(
          metaDataCache.containsKey('sample_create_key_1🛠.wavi@test_user_1'),
          true);
    });

    test(
        'A test to verify key created via create method without TTL and TTB is not added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_put_1'
        ..metaData = (AtMetaData()..isEncrypted = false);
      final testKey = 'sample_data_put_1.wavi@test_user_1';
      await keystore.create(testKey, atData);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache.containsKey(testKey), false);
    });

    test(
        'A test to verify key created via create method with TTL is added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_put_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttl = 10000);
      final testKey = 'sample_put_key_2🛠.wavi@test_user_1';
      await keystore.create(testKey, atData);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache.containsKey(testKey), true);
    });

    test(
        'A test to verify key created via create method with TTB is added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_put_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttb = 10000);
      final testKey = 'sample_put_key_2🛠.wavi@test_user_1';
      await keystore.create(testKey, atData);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache.containsKey(testKey), true);
    });

    test(
        'A test to verify key created via create method with TTB and TTL is added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_put_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = false
          ..ttl = 10000
          ..ttb = 10000);
      final testKey = 'sample_put_key_2🛠.wavi@test_user_1';
      await keystore.create(testKey, atData);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache.containsKey(testKey), true);
    });

    test('A test to verify deleted key is removed from metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data_remove_2'
        ..metaData = (AtMetaData()
          ..isEncrypted = true
          ..ttl = 10000);
      final testKey = 'sample_remove_key_2🛠.wavi@test_user_1';
      await keystore.put(testKey, atData);
      final int cacheEntriesCountBeforeRemove =
          keystore.getExpiryKeysCache().length;
      final removeResult = await keystore.remove(testKey);
      expect(removeResult, isNotNull);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(metaDataCache, isNotNull);
      expect(metaDataCache.length, cacheEntriesCountBeforeRemove - 1);
      expect(metaDataCache.containsKey(testKey), false);
    });

    test(
        'A test to verify deleting a key which is not present in metaDataCache does not raise exception',
        () async {
      String atSign = '@test_user_1';
      HiveAtKeyValueStore keystore = testKeyStoreFor(atSign);
      AtData atData = AtData()
        ..data = 'sample_data_remove_4'
        ..metaData = (AtMetaData()..isEncrypted = false);
      final testKey = 'non_existent_key.wavi$atSign';
      await keystore.put(testKey, atData);
      await keystore.remove(testKey);
    });

    test('A test to verify metaDataCache with put and remove operations',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'value_test_1'
        ..metaData = (AtMetaData()..ttl = 10000);
      // The key will be inserted into metadata cache
      await keystore.put('key_test_1.wavi@test_user_1', atData);
      AtMetaData? getMetaResult =
          await keystore.getMeta('key_test_1.wavi@test_user_1');
      expect(getMetaResult?.ttl, 10000);
      await keystore.remove('key_test_1.wavi@test_user_1');
      expect(await keystore.getMeta('key_test_1.wavi@test_user_1'), null);
    });

    test(
        'A test to verify key updated via putMeta method is added to metaDataCache',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'value_test_2'
        ..metaData = (AtMetaData()..ttl = 10000);
      await keystore.put('key_test_2.wavi@test_user_1', atData);
      await keystore.putMeta(
          'key_test_2.wavi@test_user_1', AtMetaData()..ttl = 300000);
      AtMetaData? newMeta =
          await keystore.getMeta('key_test_2.wavi@test_user_1');
      expect(newMeta?.ttl, 300000);
    });

    test('A test to verify metaDataCache with sequence of put operation',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'dummy_data'
        ..metaData = (AtMetaData()
          ..ttl = 1000
          ..ttb = 10000);
      for (int i = 1; i <= 5; i++) {
        final testKey = 'sample_data_put_$i.wavi@test_user_1';
        atData.data = 'sample_data_put_$i';
        await keystore.create(testKey, atData);
      }
      final metaDataCache = keystore.getExpiryKeysCache();
      for (int i = 1; i <= 5; i++) {
        final testKey = 'sample_data_put_$i.wavi@test_user_1';
        atData.data = 'sample_data_put_$i';
        expect(await keystore.exists(testKey), true);
        expect(metaDataCache.containsKey(testKey), true);
      }
    });

    test(
        'test random sequence of put operations and delete operation - check cache and keystore entries',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'sample_data'
        ..metaData = (AtMetaData()..ttl = 10000);
      // put 3 keys
      final testKey_1 = 'sample_data_put_1.wavi@test_user_1';
      await keystore.create(testKey_1, atData);
      final testKey_2 = 'sample_data_put_2.wavi@test_user_1';
      await keystore.create(testKey_2, atData);
      final testKey_3 = 'sample_data_put_3.wavi@test_user_1';
      await keystore.create(testKey_3, atData);

      // delete 2 keys
      await keystore.remove(testKey_3);
      await keystore.remove(testKey_2);
      final metaDataCache = keystore.getExpiryKeysCache();
      expect(await keystore.exists(testKey_1), true);
      expect(metaDataCache.containsKey(testKey_1), true);
      expect(await keystore.exists(testKey_2), false);
      expect(metaDataCache.containsKey(testKey_2), false);
      expect(await keystore.exists(testKey_3), false);
      expect(metaDataCache.containsKey(testKey_3), false);
    });

    test('A test to verify new metadata is returned when TTL is unset',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'dummy_value'
        ..metaData = (AtMetaData()..ttl = 10000);
      await keystore.put('dummykey.wavi@test_user_1', atData);
      AtData updatedAtData = AtData()
        ..data = 'updated_value'
        ..metaData = (AtMetaData()
          ..ttl = 0
          ..ttr = -1
          ..ttb = null);
      await keystore.put(
        'dummykey.wavi@test_user_1',
        updatedAtData,
      );
      AtMetaData? atMetaData =
          await keystore.getMeta('dummykey.wavi@test_user_1');
      expect(atMetaData?.ttr, -1);
      expect(atMetaData?.ttl, 0);
    });

    test(
        'A test to verify getExpiredKeys method returns the keys whose TTL is met eventually',
        () async {
      HiveAtKeyValueStore keystore = testKeyStoreFor('@test_user_1');
      AtData atData = AtData()
        ..data = 'dummy_value'
        ..metaData = (AtMetaData()..ttl = 30);
      await keystore.put('keyabouttoexpire.wavi@test_user_1', atData);
      var expiredKeysList = await (await keystore.getExpiredKeys()).toList();
      expect(
          expiredKeysList.contains('keyabouttoexpire.wavi@test_user_1'), false);
      await Future.delayed(Duration(milliseconds: 31));
      expiredKeysList = await (await keystore.getExpiredKeys()).toList();
      expect(
          expiredKeysList.contains('keyabouttoexpire.wavi@test_user_1'), true);
    });
    tearDown(() async => await tearDownFunc(atSign));
  });

  group('A group of test related to getKeys method', () {
    String atSign = '@emoji🛠️';
    late HiveAtKeyValueStore keystore;

    setUp(() async {
      await setUpFunc(storageDir, atSign);
      keystore = testKeyStoreFor(atSign);
    });
    tearDown(() async => await tearDownFunc(atSign));

    test('A test to verify getKeys does not return expired keys', () async {
      AtData atData = AtData()
        ..data = 'value_test_4'
        // Adding TTL of 10 milliseconds
        ..metaData = (AtMetaData()..ttl = 30);
      await keystore.put('expired_key.wavi$atSign', atData);
      // Adding delay for the key to expire.
      await Future.delayed(Duration(milliseconds: 31));
      List<String> keysList = (await (await keystore.getKeys()).toList());
      expect(keysList.contains('expired_key.wavi$atSign'), false);
    });

    test('A test to verify getKeys does not return keys whose TTB is met',
        () async {
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData()..ttb = 300000);
      await keystore.put('key_test_3.wavi$atSign', atData);
      List<String> keysList = (await (await keystore.getKeys()).toList());
      expect(keysList.contains('key_test_3.wavi$atSign'), false);
    });

    test('test to verify metadata of all keys is cached', () async {
      AtData? atData = AtData();
      AtMetaData? metaData;
      //inserting sample keys
      for (int i = 0; i < 30; i++) {
        //inserting random metaData to induce variance in data
        metaData = AtMetadataBuilder(
          newAtMetaData: AtMetaData()
            ..ttl = 12000 + i.toInt()
            ..ttb = i
            ..isBinary = true,
          atSign: '@atsign_$i',
        ).build();

        atData.data = 'value_test_$i';
        atData.metaData = metaData;
        await keystore.put('key_test_$i.wavi$atSign', atData);
      }

      List<String> keys = (await (await keystore.getKeys()).toList());

      for (var key in keys) {
        atData = await keystore.get(key);
        metaData = atData?.metaData;
        expect((await keystore.getMeta(key)).toString(), metaData.toString());
      }
    });

    test('A test to verify getKeys return key with emoji', () async {
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData());
      await keystore.put('emoji_🛠️.wavi$atSign', atData);
      List<String> keysList = (await (await keystore.getKeys()).toList());
      print(keysList);
      expect(keysList.contains('emoji_🛠️.wavi$atSign'), true);
    });

    test('A test to verify getKeys returns key with emoji when TTB is set',
        () async {
      int i = 0;
      int ttb = 30;
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData()..ttb = ttb);
      final k = 'emoji_🛠️.${i + 1}.wavi$atSign';

      await keystore.put(k, atData, skipCommit: true);
      List<String> keysList = (await (await keystore.getKeys()).toList());
      expect(keysList.contains(k), false);

      await Future.delayed(Duration(milliseconds: ttb + 1));

      keysList = (await (await keystore.getKeys()).toList());
      expect(keysList.contains(k), true);

      await keystore.remove(k, skipCommit: true);
    });

    test(
        'A test to verify getKeys does not return key with emoji when TTL is set',
        () async {
      int i = 0;
      int ttl = 30;
      AtData atData = AtData()
        ..data = 'value_test_3'
        ..metaData = (AtMetaData()..ttl = ttl);
      final k = 'emoji_🛠️.${i + 1}.wavi$atSign';

      await keystore.put(k, atData);
      List<String> keysList = (await (await keystore.getKeys()).toList());
      expect(keysList.contains(k), true);

      await Future.delayed(Duration(milliseconds: ttl + 1));

      keysList = (await (await keystore.getKeys()).toList());
      expect(keysList.contains(k), false);

      await keystore.remove(k, skipCommit: true);
    });
  });

  group('A group of tests to verify skip commit', () {
    String atSign = '@test_user_1';
    setUp(() async => await setUpFunc(storageDir, atSign));
    test('skip commit true in put', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var result = await keyValueStore.put('phone.wavi@test_user_1', atData,
          skipCommit: true);
      expect(result, -1);
      var commitLogInstance = (await testCommitLogFor('@test_user_1'));
      expect(commitLogInstance.getLatestCommitEntry('phone.wavi@test_user_1'),
          isNull);
    });
    test('skip commit true in create', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var result = await keyValueStore.create('email.wavi@test_user_1', atData,
          skipCommit: true);
      expect(result, -1);
      var commitLogInstance = (await testCommitLogFor('@test_user_1'));
      expect(commitLogInstance.getLatestCommitEntry('email.wavi@test_user_1'),
          isNull);
    });
    test('skip commit true in remove', () async {
      var keyValueStore = testKeyStoreFor('@test_user_1');
      var atData = AtData();
      atData.data = '123';
      var result = await keyValueStore.remove('firstname.wavi@test_user_1',
          skipCommit: true);
      expect(result, -1);
      var commitLogInstance = (await testCommitLogFor('@test_user_1'));
      expect(
          commitLogInstance.getLatestCommitEntry('firstname.wavi@test_user_1'),
          isNull);
    });
    tearDown(() async => await tearDownFunc(atSign));
  });
}

Future<void> tearDownFunc(String atSign) async {
  await Hive.deleteBoxFromDisk('commit_log_$atSign');
  await Hive.deleteBoxFromDisk(_getShaForAtSign(atSign));
  await tearDownTestPersistence(storageDir: 'test/hive');
}

Future<void> setUpFunc(String storageDir, String atSign) =>
    setUpTestKeyStore(atSign, storageDir: storageDir);

String _getShaForAtSign(String atSign) {
  var bytes = utf8.encode(atSign);
  return sha256.convert(bytes).toString();
}
