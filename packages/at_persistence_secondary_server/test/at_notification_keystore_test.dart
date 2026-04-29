import 'dart:io';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

var atSign = '@alice';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';

  late HiveAtNotificationKeystore keyStore;
  setUp(() async {
    keyStore = HiveAtNotificationKeystore(atSign);
    await keyStore.init(storageDir);
    await keyStore.init('$storageDir/${Uuid().v4()}');
  });
  tearDown(() async {
    await keyStore.close();
    var isExists = await Directory('test/hive/').exists();
    if (isExists) {
      await Directory('test/hive').delete(recursive: true);
    }
  });

  group('A group of notification keystore impl tests', () {
    test('test put and get', () async {
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
      var atMetaData = AtMetaData.fromCommonsMetadata(commonsMetadata, atSign);
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..id = '123'
            ..atMetaData = atMetaData)
          .build();
      await keyStore.put(atNotification.id, atNotification);
      final value = await keyStore.get(atNotification.id);
      expect(value, isNotNull);
      expect(value!.id, '123');
      expect(value.atMetadata?.skeEncKeyName, commonsMetadata.skeEncKeyName);
      expect(value.atMetadata?.toCommonsMetadata(), commonsMetadata);
    });
    test('test remove', () async {
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..id = '123')
          .build();
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.remove(atNotification.id);
      final value = await keyStore.get(atNotification.id);
      expect(value, isNull);
    });
    test('test delete expired keys - key expired', () async {
      int ttl = 10;
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..ttl = ttl
            ..id = '123')
          .build();
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.deleteExpiredKeys();
      expect((await keyStore.get(atNotification.id))?.toAtSign, '@bob');

      sleep(Duration(milliseconds: ttl + 1));
      await keyStore.deleteExpiredKeys();
      expect(await keyStore.get(atNotification.id), isNull);
    });
    test('test delete expired keys - key not expired', () async {
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..ttl = 10
            ..id = '123')
          .build();
      await keyStore.put(atNotification.id, atNotification);
      await keyStore.deleteExpiredKeys();
      final value = await keyStore.get(atNotification.id);
      expect(value, isNotNull);
      expect(value!.id, '123');
    });
    test('test get expired keys - multiple keys expired', () async {
      var atNotification_1 = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..ttl = 5
            ..id = '111')
          .build();
      var atNotification_2 = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = atSign
            ..ttl = 20
            ..id = '222')
          .build();
      var atNotification_3 = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = atSign
            ..ttl = 10
            ..id = '333')
          .build();
      await keyStore.put(atNotification_1.id, atNotification_1);
      await keyStore.put(atNotification_2.id, atNotification_2);
      await keyStore.put(atNotification_3.id, atNotification_3);
      sleep(Duration(milliseconds: 11));
      var expiredKeys = await keyStore.getExpiredKeys();
      expect(expiredKeys.length, 2);
      expect('111', expiredKeys.elementAt(0));
      expect('333', expiredKeys.elementAt(1));
      sleep(Duration(milliseconds: 11));
      expiredKeys = await keyStore.getExpiredKeys();
      expect(expiredKeys.length, 3);
      expect('111', expiredKeys.elementAt(0));
      expect('222', expiredKeys.elementAt(1));
      expect('333', expiredKeys.elementAt(2));
    });
    test('test get expired keys - no keys expired', () async {
      var atNotification_1 = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..ttl = 3000
            ..id = '111')
          .build();
      var atNotification_2 = (AtNotificationBuilder()
            ..toAtSign = '@charlie'
            ..fromAtSign = atSign
            ..ttl = 4000
            ..id = '222')
          .build();
      var atNotification_3 = (AtNotificationBuilder()
            ..toAtSign = '@dave'
            ..fromAtSign = atSign
            ..ttl = 5000
            ..id = '333')
          .build();
      await keyStore.put(atNotification_1.id, atNotification_1);
      await keyStore.put(atNotification_2.id, atNotification_2);
      await keyStore.put(atNotification_3.id, atNotification_3);
      var expiredKeys = await keyStore.getExpiredKeys();
      expect(0, expiredKeys.length);
    });
    test('test hive key exceeds max allowed chars', () async {
      var atNotification = (AtNotificationBuilder()
            ..toAtSign = '@bob'
            ..fromAtSign = atSign
            ..id = '123')
          .build();
      var key = '${TestUtils.generateRandomString(245)}@alice';
      await expectLater(
          keyStore.put(key, atNotification),
          throwsA(predicate((dynamic e) =>
              e is DataStoreException &&
              e.message ==
                  "key length ${key.length} is greater than ${HiveAtNotificationKeystore.maxKeyLengthWithoutCached} chars")));
    });
  });
}
