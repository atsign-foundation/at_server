import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  var redisUrl = 'redis://localhost:6379';
  var redisPassword = 'mypassword';
  setUp(() async => await setUpFunc(redisUrl, redisPassword));
  group('A group of redis keystore impl tests', () {
    test('test update', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var atData = AtData();
      atData.data = '123';
      var result = await keyStore.create('phone', atData);
      expect(result, isNotNull);
    });

    test('test create and get', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var atData = AtData();
      atData.data = '123';
      await keyStore.create('phone', atData);
      var dataFromRedis = await keyStore.get('phone');
      expect(dataFromRedis.data, '123');
    });

    test('test create, update and get', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var atData = AtData();
      atData.data = 'india';
      await keyStore.create('location', atData);
      var updateData = AtData();
      updateData.data = 'united states';
      await keyStore.put('location', updateData);
      var dataFromRedis = await keyStore.get('location');
      expect(dataFromRedis.data, 'united states');
    });

    test('test update and get', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var updateData = AtData();
      updateData.data = 'alice';
      await keyStore.put('last_name', updateData);
      var dataFromRedis = await keyStore.get('last_name');
      expect(dataFromRedis.data, 'alice');
    });

    test('test update and remove', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var updateData = AtData();
      updateData.data = 'alice';
      await keyStore.put('last_name', updateData);
      await keyStore.remove('last_name');
      var dataFromRedis = await keyStore.get('last_name');
      expect(dataFromRedis, isNull);
    });

    test('get keys', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var data_1 = AtData();
      data_1.data = 'alice';
      await keyStore.put('last_name', data_1);
      var data_2 = AtData();
      data_2.data = 'bob';
      await keyStore.put('first_name', data_2);
      var keys = await keyStore.getKeys();
      expect(keys.length, 2);
    });

    test('test get null key', () {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      expect(() async => await keyStore.get(null),
          throwsA(predicate((e) => e is AssertionError)));
    });

    test('test get expired keys - no data', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var expiredKeys = await keyStore.getExpiredKeys();
      expect(expiredKeys.length, 0);
    });

    test('test delete expired keys - no data', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var result = await keyStore.deleteExpiredKeys();
      expect(result, true);
    });

    test('get keys by regex', () async {
      var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore('@test_user_1');
      var keyStore = keyStoreManager.getSecondaryKeyStore();
      var data_1 = AtData();
      data_1.data = 'alice';
      await keyStore.put('last_name', data_1);
      var data_2 = AtData();
      data_2.data = 'bob';
      await keyStore.put('first_name', data_2);
      var keys = await keyStore.getKeys(regex: '^first');
      expect(keys.length, 1);
    });

  });
  try {
    tearDown(() async => await tearDownFunc());
  } on Exception catch (e) {
    print('error in tear down:${e.toString()}');
  }
}

Future<void> tearDownFunc() async {

}

Future<void> setUpFunc(var redisURL, var redisPassword) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getRedisCommitLog('@test_user_1', redisURL, password: redisPassword);
  var persistenceManager = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@test_user_1');
  await persistenceManager
      .getPersistenceManager()
      .init('@test_user_1', redisURL, password: redisPassword);
  var keyStore;
  keyStore = persistenceManager.getSecondaryKeyStore();
  keyStore.commitLog = commitLogInstance;
}
