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
  var storageDir = Directory.current.path + '/test/hive';
  setUp(() async => await setUpFunc(storageDir));
  group('A group of hive keystore impl tests', () {
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
      var atData = AtData();
      atData.data = 'india';
      await keyStore.create('location.wavi@test_user_1', atData);
      var updateData = AtData();
      updateData.data = 'united states';
      await keyStore.put('location.wavi@test_user_1', updateData);
      var dataFromHive = await (keyStore.get('location.wavi@test_user_1'));
      expect(dataFromHive?.data, 'united states');
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
      expect((() async => await keyStore.put('privatekey:mykey', atData)),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test create invalid key', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      expect((() async => await keyStore.create('hello123', atData)),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test put invalid key', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      expect((() async => await keyStore.put('hello@', atData)),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test create non reserved key- keystore putAll', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      expect((() async => await keyStore.put('privatekey:mykey', atData)),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });

    test('test putAll invalid key', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1')!;
      var keyStore = keyStoreManager.getSecondaryKeyStore()!;
      var atData = AtData();
      atData.data = '123';
      expect((() async => await keyStore.put('hello@', atData)),
          throwsA(predicate((dynamic e) => e is InvalidAtKeyException)));
    });
// tests commented for coverage. runs fine with pub run test or in IDE
//    test('test expired keys - 1 key', ()  async {
//      var keyStore = keyStoreManager.getKeyStore();
//      AtData updateData = new AtData();
//      updateData.data = 'alice';
//      bool result = await keyStore.put('last_name', updateData,expiry:Duration(seconds: 5));
//      expect(result, true);
//      AtData expiredValue  = await Future.delayed(Duration(minutes: 1,seconds: 30), () => keyStoreManager.getKeyStore().get('last_name'));
//      expect(expiredValue, isNull);
//    }, timeout: Timeout(Duration(minutes: 3)));
//
//    test('test get expired keys - 1 key', ()  async {
//      var keyStore = keyStoreManager.getKeyStore();
//      AtData updateData = new AtData();
//      updateData.data = 'alice';
//      bool result = await keyStore.put('last_name', updateData,expiry:Duration(milliseconds: 10));
//      expect(result, true);
//      List<String> expiredKeys  = await Future.delayed(Duration(seconds: 1), () => keyStoreManager.getKeyStore().getExpiredKeys());
//      print(expiredKeys);
//      expect(expiredKeys[0], 'last_name');
//    }, timeout: Timeout(Duration(minutes: 1)));
//
//    test('test get expired keys - no expired key', ()  async {
//      var keyStore = keyStoreManager.getKeyStore();
//      AtData updateData = new AtData();
//      updateData.data = 'alice';
//      bool result = await keyStore.put('last_name', updateData,expiry:Duration(minutes: 10));
//      expect(result, true);
//      List<String> expiredKeys  = await Future.delayed(Duration(seconds: 30), () => keyStoreManager.getKeyStore().getExpiredKeys());
//      print(expiredKeys);
//      expect(expiredKeys.length, 0);
//    }, timeout: Timeout(Duration(minutes: 1)));
  });

  group('A group of tests to verify compaction', () {
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
      expect(locationList?.getSize(), 50);
      await keyStore.put('@bob:location.wavi@test_user_1', atData);
      expect(locationList?.getSize(), 1);
    });
  });

  group('Verify metadata cache', () {
    test('test to verify put and remove', () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData();
      atData.data = 'value_test_1';
      AtMetaData meta = AtMetaData();
      meta.ttl = 11;
      atData.metaData = meta;
      await keystore?.put('key_test_1.wavi@test_user_1', atData);
      AtMetaData? getMetaResult =
          await keystore?.getMeta('key_test_1.wavi@test_user_1');
      expect(getMetaResult?.ttl, 11);
      await keystore?.remove('key_test_1.wavi@test_user_1');
      AtMetaData? getMetaResult1 =
          await keystore?.getMeta('key_test_1.wavi@test_user_1');
      expect(getMetaResult1?.ttl, null);
    });

    test('test to verify putMeta', () async {
      SecondaryPersistenceStore? keyStoreManager =
          SecondaryPersistenceStoreFactory.getInstance()
              .getSecondaryPersistenceStore('@test_user_1');
      HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
      AtData atData = AtData();
      atData.data = 'value_test_2';
      AtMetaData meta = AtMetaData();
      meta.ttl = 112;
      atData.metaData = meta;
      await keystore?.put('key_test_2.wavi@test_user_1', atData);
      meta.ttl = 131;
      await keystore?.putMeta('key_test_2.wavi@test_user_1', meta);
      AtMetaData? newMeta =
          await keystore?.getMeta('key_test_2.wavi@test_user_1');
      expect(newMeta?.ttl, 131);
    });
  });

  test('test to verify if getKeys returns expired keys', () async {
    SecondaryPersistenceStore? keyStoreManager =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore('@test_user_1');
    HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
    AtData atData = AtData();
    atData.data = 'value_test_4';
    AtMetaData meta = AtMetaData();
    meta.expiresAt =
        DateTime.now().toUtc().subtract(const Duration(minutes: 100));
    atData.metaData = meta;
    await keystore?.put('key_test_4.wavi@test_user_1', atData);
    List<String>? keysList = keystore?.getKeys();
    expect(keysList!.contains('key_test_4.wavi@test_user_1'), false);
  });

  test('test to verify if getKeys returns unborn keys', () async {
    SecondaryPersistenceStore? keyStoreManager =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore('@test_user_1');
    HiveKeystore? keystore = keyStoreManager?.getSecondaryKeyStore();
    AtData atData = AtData();
    atData.data = 'value_test_3';
    AtMetaData meta = AtMetaData();
    meta.availableAt = DateTime.now().toUtc().add(const Duration(minutes: 100));
    atData.metaData = meta;
    await keystore?.put('key_test_3.wavi@test_user_1', atData);
    List<String>? keysList = keystore?.getKeys();
    expect(keysList!.contains('key_test_3.wavi@test_user_1'), false);
  });

  test('test to verify metadata of all keys is cached', () async {
    SecondaryPersistenceStore? keystoreManager =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore('@test_user_1');
    HiveKeystore? keystore = keystoreManager?.getSecondaryKeyStore();
    AtData? atData = AtData();
    AtMetaData? metaData;
    //inserting sample keys
    for (int i = 0; i < 30; i++) {
      if (i % 2 == 0) {
        //inserting random metaData to induce variance in data
        metaData = AtMetaData();
        metaData.ttl = 12000 + i.toInt();
        metaData.ttb = i;
        metaData.createdBy = '$i';
        metaData.updatedBy = '$i';
        metaData.isBinary = true;
      }
      atData.data = 'value_test_$i';
      atData.metaData = metaData;
      await keystore?.put('key_test_$i.wavi@test_user_1', atData);
    }

    List<String>? keys = keystore?.getKeys();

    keys?.forEach((String key) async {
      atData = await keystore?.get(key);
      metaData = atData?.metaData;
      AtMetaData? getMeta = await keystore?.getMeta(key);
      //parsing timestamps to remove microseconds as they differ precision
      getMeta?.updatedAt =
          DateTime.parse(getMeta.updatedAt.toString().substring(0, 19));
      metaData?.updatedAt =
          DateTime.parse(metaData!.updatedAt.toString().substring(0, 19));
      getMeta?.createdAt =
          DateTime.parse(getMeta.createdAt.toString().substring(0, 19));
      metaData?.createdAt =
          DateTime.parse(metaData!.createdAt.toString().substring(0, 19));
      getMeta?.availableAt =
          DateTime.parse(getMeta.availableAt.toString().substring(0, 19));
      metaData?.availableAt =
          DateTime.parse(metaData!.availableAt.toString().substring(0, 19));
      getMeta?.expiresAt =
          DateTime.parse(getMeta.expiresAt.toString().substring(0, 19));
      metaData?.expiresAt =
          DateTime.parse(metaData!.expiresAt.toString().substring(0, 19));

      expect((await keystore?.getMeta(key)).toString(), metaData.toString());
    });
  });

  try {
    tearDown(() async => await tearDownFunc());
  } on Exception catch (e) {
    print('error in tear down:${e.toString()}');
  }
}

Future<void> tearDownFunc() async {
  await Hive.deleteBoxFromDisk('commit_log_@test_user_1');
  await Hive.deleteBoxFromDisk(_getShaForAtsign('@test_user_1'));
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}

Future<void> setUpFunc(storageDir) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@test_user_1', commitLogPath: storageDir);
  var persistenceManager = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@test_user_1')!;
  await persistenceManager.getHivePersistenceManager()!.init(storageDir);
  persistenceManager.getSecondaryKeyStore()!.commitLog = commitLogInstance;
}

String _getShaForAtsign(String atsign) {
  var bytes = utf8.encode(atsign);
  return sha256.convert(bytes).toString();
}
