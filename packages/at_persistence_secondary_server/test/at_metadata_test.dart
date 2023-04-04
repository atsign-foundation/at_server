import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:collection/collection.dart';
import 'package:test/test.dart';

void main() async {
  var storageDir = '${Directory.current.path}/test/hive';
  var atSign = '@alice';

  group('A group of tests to verify at_metadata fields', () {
    setUpAll(() async => await setUpFunc(storageDir));

    /// The below test is to verify the default fields in the metadata are populated
    /// on creation of a new key
    /// The default fields are:
    ///   For new key createdAt and UpdatedAt are same
    /// a) CreatedAt - DateTime when the key is created
    /// b) UpdatedAt - DateTime when the key is updated
    /// c) CreatedBy - The atSign which created the key
    /// d) version - Indicates the number of times the key is updated.
    ///              For a new key version is set to 0
    test('A test to default field in metadata is set on a new key creation',
        () async {
      var keyCreationDateTime = DateTime.now().toUtcMillisecondsPrecision();
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();
      var key = '@bob:phone@alice';
      var value = '9878123321';
      await hiveKeyStore?.put(key, AtData()..data = value);
      var atData = await hiveKeyStore?.get(key);
      expect(atData?.data, value);
      expect(
          atData!.metaData!.createdAt!.millisecondsSinceEpoch >=
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(
          atData.metaData!.updatedAt!.millisecondsSinceEpoch >=
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(atData.metaData!.createdBy, atSign);
      expect(atData.metaData!.version, 0);
    });

    /// The below test is to verify the default fields in the metadata are populated
    /// on update of an existing key
    /// The default fields are:
    /// a) CreatedAt - DateTime when the key is created
    /// b) UpdatedAt - DateTime when the key is updated
    /// c) CreatedBy - The atSign which created the key
    /// d) version - Indicates the number of times the key is updated.
    ///              For a new key version is set to 0
    test(
        'A test to verify version field in metadata is set to 1 on updating the existing key',
        () async {
      var keyCreationDateTime = DateTime.now().toUtcMillisecondsPrecision();
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();
      var key = '@bob:mobile@alice';
      var value = '9878123321';
      await hiveKeyStore?.put(key, AtData()..data = value);
      // Update the same key
      var updateKeyDateTime = DateTime.now().toUtcMillisecondsPrecision();
      await hiveKeyStore?.put(key, AtData()..data = '9878123322');
      var atData = await hiveKeyStore?.get(key);
      expect(atData?.data, '9878123322');
      expect(
          atData!.metaData!.createdAt!.millisecondsSinceEpoch >=
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(
          atData.metaData!.updatedAt!.millisecondsSinceEpoch >=
              updateKeyDateTime.millisecondsSinceEpoch,
          true);
      expect(atData.metaData!.createdBy, atSign);
      expect(atData.metaData!.version, 1);
    });

    test(
        'A test to verify version field in metadata is set to 1 when updating metadata using putMeta method',
        () async {
      var keyCreationDateTime = DateTime.now().toUtcMillisecondsPrecision();
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();
      var key = '@bob:country@alice';
      var value = '9878123321';
      await hiveKeyStore?.put(key, AtData()..data = value);
      // Update the same key
      var updateKeyDateTime = DateTime.now().toUtcMillisecondsPrecision();
      await hiveKeyStore?.putMeta(key, AtMetaData()..ttl = 10000);
      var atData = await hiveKeyStore?.get(key);
      expect(atData?.data, value);
      expect(
          atData!.metaData!.createdAt!.millisecondsSinceEpoch >=
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(
          atData.metaData!.updatedAt!.millisecondsSinceEpoch >=
              updateKeyDateTime.millisecondsSinceEpoch,
          true);
      expect(atData.metaData!.createdBy, atSign);
      expect(atData.metaData!.version, 1);
    });

    test(
        'A test to verify version field in metadata is set to 1 when using putAll method',
        () async {
      var keyCreationDateTime = DateTime.now().toUtcMillisecondsPrecision();
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();
      var key = '@bob:city@alice';
      await hiveKeyStore?.putAll(
          key, AtData()..data = '9878123322', AtMetaData());
      // Update the same key
      var updateKeyDateTime = DateTime.now().toUtcMillisecondsPrecision();
      await hiveKeyStore?.putAll(
          key, AtData()..data = '9878123322', AtMetaData()..ttl = 10000);
      var atData = await hiveKeyStore?.get(key);
      expect(atData?.data, '9878123322');
      expect(
          atData!.metaData!.createdAt!.millisecondsSinceEpoch >=
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(
          atData.metaData!.updatedAt!.millisecondsSinceEpoch >=
              updateKeyDateTime.millisecondsSinceEpoch,
          true);
      expect(atData.metaData!.createdBy, atSign);
      expect(atData.metaData!.version, 1);
      expect(atData.metaData!.ttl, 10000);
    });
    tearDownAll(() async => await tearDownFunc());
  });
  group('A group of tests to verify at_metadata adapter', () {
    test('at_meta_data adapter test', () async {
      final metaData = Metadata()
        ..ttl = 1000
        ..ccd = true
        ..pubKeyCS = 'xyz'
        ..sharedKeyEnc = 'abc'
        ..isBinary = false;
      final atMetaData = AtMetaData.fromCommonsMetadata(metaData);
      expect(atMetaData.ttl, 1000);
      expect(atMetaData.isCascade, true);
      expect(atMetaData.pubKeyCS, 'xyz');
      expect(atMetaData.sharedKeyEnc, 'abc');
      expect(atMetaData.isBinary, false);
    });
  });

  group('Test json round-tripping', () {
    test('Test without null values', () {
      final Metadata startMetaData = Metadata()
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
      final AtMetaData startAtMetaData =
          AtMetaData.fromCommonsMetadata(startMetaData);
      final Map startMap = startAtMetaData.toJson();
      final String startJson = jsonEncode(startMap);
      final Map endMap = jsonDecode(startJson);
      expect(DeepCollectionEquality().equals(endMap, startMap), true);
      AtMetaData endAtMetaData = AtMetaData().fromJson(endMap);
      expect(endAtMetaData, startAtMetaData);
      final Metadata endMetaData = endAtMetaData.toCommonsMetadata();
      expect(endMetaData, startMetaData);
    });
    test('Test with null values', () {
      final Metadata startMetaData = Metadata()
        ..ttl = null
        ..ttb = null
        ..ttr = null
        ..ccd = false
        ..isBinary = true
        ..isEncrypted = false
        ..dataSignature = null
        ..pubKeyCS = null
        ..sharedKeyEnc = null
        ..encoding = null
        ..encKeyName = null
        ..encAlgo = null
        ..ivNonce = null
        ..skeEncKeyName = null
        ..skeEncAlgo = null;
      final AtMetaData startAtMetaData =
          AtMetaData.fromCommonsMetadata(startMetaData);
      final Map startMap = startAtMetaData.toJson();
      final String startJson = jsonEncode(startMap);
      final Map endMap = jsonDecode(startJson);
      expect(DeepCollectionEquality().equals(endMap, startMap), true);
      AtMetaData endAtMetaData = AtMetaData().fromJson(endMap);
      expect(endAtMetaData, startAtMetaData);
      final Metadata endMetaData = endAtMetaData.toCommonsMetadata();
      expect(endMetaData, startMetaData);
    });
    test('Test with some null, some non-null values', () {
      final Metadata startMetaData = Metadata()
        ..ttl = 0
        ..ttb = 0
        ..ttr = 0
        ..ccd = false
        ..isBinary = true
        ..isEncrypted = false
        ..dataSignature = 'foo'
        ..pubKeyCS = null
        ..sharedKeyEnc = null
        ..encoding = 'base64'
        ..encKeyName = 'someEncKeyName'
        ..encAlgo = 'AES/CTR/PKCS7Padding'
        ..ivNonce = 'someIvOrNonce'
        ..skeEncKeyName = null
        ..skeEncAlgo = null;
      final AtMetaData startAtMetaData =
          AtMetaData.fromCommonsMetadata(startMetaData);
      final Map startMap = startAtMetaData.toJson();
      final String startJson = jsonEncode(startMap);
      final Map endMap = jsonDecode(startJson);
      expect(DeepCollectionEquality().equals(endMap, startMap), true);
      AtMetaData endAtMetaData = AtMetaData().fromJson(endMap);
      expect(endAtMetaData, startAtMetaData);
      final Metadata endMetaData = endAtMetaData.toCommonsMetadata();
      expect(endMetaData, startMetaData);
    });
  });

  group('A group of tests to assert metadata when key is updated', () {
    setUpAll(() async => await setUpFunc(storageDir));

    test(
        'A test to verify existing metadata is retained when key is updated using put method',
        () async {
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();
      String key = '@bob:phone@alice';
      String value = '9878123321';
      AtMetaData atMetaData = AtMetaData()
        ..ttl = 100
        ..ttb = 100
        ..ttr = 1000
        ..isCascade = true
        ..isBinary = true
        ..isEncrypted = true
        ..dataSignature = 'dummy_data_signature'
        ..sharedKeyEnc = 'dummy_shared_key_env'
        ..pubKeyCS = 'dummy_public_key_cs'
        ..encoding = 'base64'
        ..encKeyName = 'dummy_enc_key'
        ..encAlgo = 'rsa'
        ..ivNonce = 'dummy_ivnonce'
        ..skeEncKeyName = 'dummy_ske'
        ..skeEncAlgo = 'dummy_ske_enc_algo';

      AtData atData = AtData()
        ..data = value
        ..metaData = atMetaData;
      await hiveKeyStore?.put(key, atData);
      // Update the key with a no metadata
      AtMetaData newAtMetaData = AtMetaData();
      AtData newAtData = AtData()
        ..data = value
        ..metaData = newAtMetaData;
      await hiveKeyStore?.put(key, newAtData);

      AtData? atDataResponse = await hiveKeyStore?.get(key);
      expect(atDataResponse?.metaData?.ttl, 100);
      expect(atDataResponse?.metaData?.ttb, 100);
      expect(atDataResponse?.metaData?.ttr, 1000);
      expect(atDataResponse?.metaData?.isCascade, true);
      expect(atDataResponse?.metaData?.isBinary, true);
      expect(atDataResponse?.metaData?.isEncrypted, true);
      expect(atDataResponse?.metaData?.dataSignature, 'dummy_data_signature');
      expect(atDataResponse?.metaData?.sharedKeyEnc, 'dummy_shared_key_env');
      expect(atDataResponse?.metaData?.pubKeyCS, 'dummy_public_key_cs');
      expect(atDataResponse?.metaData?.encoding, 'base64');
      expect(atDataResponse?.metaData?.encKeyName, 'dummy_enc_key');
      expect(atDataResponse?.metaData?.encAlgo, 'rsa');
      expect(atDataResponse?.metaData?.ivNonce, 'dummy_ivnonce');
      expect(atDataResponse?.metaData?.skeEncKeyName, 'dummy_ske');
      expect(atDataResponse?.metaData?.skeEncAlgo, 'dummy_ske_enc_algo');
    });

    test(
        'A test to verify new metadata overwrites the existing metadata using put method',
        () async {
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();

      String key = '@bob:phone@alice';
      String value = '9878123321';
      AtMetaData atMetaData = AtMetaData()
        ..ttl = 10
        ..ttb = 10
        ..ttr = 10
        ..isCascade = false
        ..isBinary = false
        ..isEncrypted = false
        ..dataSignature = 'dummy_data_signature_old'
        ..sharedKeyEnc = 'dummy_shared_key_env_old'
        ..pubKeyCS = 'dummy_public_key_cs_old'
        ..encoding = 'base64_old'
        ..encKeyName = 'dummy_enc_key_old'
        ..encAlgo = 'rsa_old'
        ..ivNonce = 'dummy_ivnonce_old'
        ..skeEncKeyName = 'dummy_ske_old'
        ..skeEncAlgo = 'dummy_ske_enc_algo_old';
      AtData atData = AtData()
        ..data = value
        ..metaData = atMetaData;
      await hiveKeyStore?.put(key, atData);

      // Update the key with a new metadata
      AtMetaData newAtMetaData = AtMetaData()
        ..ttl = 100
        ..ttb = 100
        ..ttr = 1000
        ..isCascade = true
        ..isBinary = true
        ..isEncrypted = true
        ..dataSignature = 'dummy_data_signature'
        ..sharedKeyEnc = 'dummy_shared_key_env'
        ..pubKeyCS = 'dummy_public_key_cs'
        ..encoding = 'base64'
        ..encKeyName = 'dummy_enc_key'
        ..encAlgo = 'rsa'
        ..ivNonce = 'dummy_ivnonce'
        ..skeEncKeyName = 'dummy_ske'
        ..skeEncAlgo = 'dummy_ske_enc_algo';

      AtData newAtData = AtData()
        ..data = value
        ..metaData = newAtMetaData;
      await hiveKeyStore?.put(key, newAtData);

      AtData? atDataResponse = await hiveKeyStore?.get(key);
      expect(atDataResponse?.metaData?.ttl, 100);
      expect(atDataResponse?.metaData?.ttb, 100);
      expect(atDataResponse?.metaData?.ttr, 1000);
      expect(atDataResponse?.metaData?.isCascade, true);
      expect(atDataResponse?.metaData?.isBinary, true);
      expect(atDataResponse?.metaData?.isEncrypted, true);
      expect(atDataResponse?.metaData?.dataSignature, 'dummy_data_signature');
      expect(atDataResponse?.metaData?.sharedKeyEnc, 'dummy_shared_key_env');
      expect(atDataResponse?.metaData?.pubKeyCS, 'dummy_public_key_cs');
      expect(atDataResponse?.metaData?.encoding, 'base64');
      expect(atDataResponse?.metaData?.encKeyName, 'dummy_enc_key');
      expect(atDataResponse?.metaData?.encAlgo, 'rsa');
      expect(atDataResponse?.metaData?.ivNonce, 'dummy_ivnonce');
      expect(atDataResponse?.metaData?.skeEncKeyName, 'dummy_ske');
      expect(atDataResponse?.metaData?.skeEncAlgo, 'dummy_ske_enc_algo');
    });

    test(
        'A test to verify new metadata is applied for fields that are modified and existing metadata is retained for the fields that are not updated',
        () async {
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();

      String key = '@bob:phone@alice';
      String value = '9878123321';
      AtMetaData atMetaData = AtMetaData()
        ..ttl = 10
        ..ttb = 10
        ..ttr = 10
        ..isCascade = false
        ..isBinary = false
        ..isEncrypted = false
        ..dataSignature = 'dummy_data_signature_old'
        ..sharedKeyEnc = 'dummy_shared_key_env_old'
        ..pubKeyCS = 'dummy_public_key_cs_old'
        ..encoding = 'base64_old'
        ..encKeyName = 'dummy_enc_key_old'
        ..encAlgo = 'rsa_old'
        ..ivNonce = 'dummy_ivnonce_old'
        ..skeEncKeyName = 'dummy_ske_old'
        ..skeEncAlgo = 'dummy_ske_enc_algo_old';
      AtData atData = AtData()
        ..data = value
        ..metaData = atMetaData;
      await hiveKeyStore?.put(key, atData);

      // Update the key with a new metadata
      AtMetaData newAtMetaData = AtMetaData()
        ..isBinary = true
        ..isEncrypted = true
        ..dataSignature = 'dummy_data_signature'
        ..sharedKeyEnc = 'dummy_shared_key_env'
        ..pubKeyCS = 'dummy_public_key_cs'
        ..encoding = 'base64'
        ..encKeyName = 'dummy_enc_key'
        ..encAlgo = 'rsa'
        ..ivNonce = 'dummy_ivnonce'
        ..skeEncKeyName = 'dummy_ske'
        ..skeEncAlgo = 'dummy_ske_enc_algo';

      AtData newAtData = AtData()
        ..data = value
        ..metaData = newAtMetaData;
      await hiveKeyStore?.put(key, newAtData);

      AtData? atDataResponse = await hiveKeyStore?.get(key);
      expect(atDataResponse?.metaData?.ttl, 10);
      expect(atDataResponse?.metaData?.ttb, 10);
      expect(atDataResponse?.metaData?.ttr, 10);
      expect(atDataResponse?.metaData?.isCascade, false);
      expect(atDataResponse?.metaData?.isBinary, true);
      expect(atDataResponse?.metaData?.isEncrypted, true);
      expect(atDataResponse?.metaData?.dataSignature, 'dummy_data_signature');
      expect(atDataResponse?.metaData?.sharedKeyEnc, 'dummy_shared_key_env');
      expect(atDataResponse?.metaData?.pubKeyCS, 'dummy_public_key_cs');
      expect(atDataResponse?.metaData?.encoding, 'base64');
      expect(atDataResponse?.metaData?.encKeyName, 'dummy_enc_key');
      expect(atDataResponse?.metaData?.encAlgo, 'rsa');
      expect(atDataResponse?.metaData?.ivNonce, 'dummy_ivnonce');
      expect(atDataResponse?.metaData?.skeEncKeyName, 'dummy_ske');
      expect(atDataResponse?.metaData?.skeEncAlgo, 'dummy_ske_enc_algo');
    });

    test('A test to verify null to new metadata reset the metadata', () async {
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(atSign)!
          .getSecondaryKeyStore();

      String key = '@bob:phone@alice';
      String value = '9878123321';
      AtMetaData atMetaData = AtMetaData()
        ..ttl = 10
        ..ttb = 10
        ..ttr = 10
        ..isCascade = false
        ..isBinary = true
        ..isEncrypted = true
        ..dataSignature = 'dummy_data_signature_old'
        ..sharedKeyEnc = 'dummy_shared_key_env_old'
        ..pubKeyCS = 'dummy_public_key_cs_old'
        ..encoding = 'base64_old'
        ..encKeyName = 'dummy_enc_key_old'
        ..encAlgo = 'rsa_old'
        ..ivNonce = 'dummy_ivnonce_old'
        ..skeEncKeyName = 'dummy_ske_old'
        ..skeEncAlgo = 'dummy_ske_enc_algo_old';
      AtData atData = AtData()
        ..data = value
        ..metaData = atMetaData;
      await hiveKeyStore?.put(key, atData);

      // Update the key with a new metadata
      AtMetaData newAtMetaData = AtMetaData()
        ..dataSignature = 'null'
        ..sharedKeyEnc = 'null'
        ..pubKeyCS = 'null'
        ..encoding = 'null'
        ..encKeyName = 'null'
        ..encAlgo = 'null'
        ..ivNonce = 'null'
        ..skeEncKeyName = 'null'
        ..skeEncAlgo = 'null';

      AtData newAtData = AtData()
        ..data = value
        ..metaData = newAtMetaData;
      await hiveKeyStore?.put(key, newAtData);

      AtData? atDataResponse = await hiveKeyStore?.get(key);
      expect(atDataResponse?.metaData?.ttl, 10);
      expect(atDataResponse?.metaData?.ttb, 10);
      expect(atDataResponse?.metaData?.ttr, 10);
      expect(atDataResponse?.metaData?.isCascade, false);
      expect(atDataResponse?.metaData?.isBinary, true);
      expect(atDataResponse?.metaData?.isEncrypted, true);
      expect(atDataResponse?.metaData?.dataSignature, null);
      expect(atDataResponse?.metaData?.sharedKeyEnc, null);
      expect(atDataResponse?.metaData?.pubKeyCS, null);
      expect(atDataResponse?.metaData?.encoding, null);
      expect(atDataResponse?.metaData?.encKeyName, null);
      expect(atDataResponse?.metaData?.encAlgo, null);
      expect(atDataResponse?.metaData?.ivNonce, null);
      expect(atDataResponse?.metaData?.skeEncKeyName, null);
      expect(atDataResponse?.metaData?.skeEncAlgo, null);
    });

    tearDownAll(() async => await tearDownFunc());
  });
}

Future<SecondaryKeyStoreManager> setUpFunc(storageDir,
    {bool enableCommitId = true}) async {
  var commitLogInstance = await AtCommitLogManagerImpl.getInstance()
      .getCommitLog('@alice',
          commitLogPath: storageDir, enableCommitId: enableCommitId);
  var secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore('@alice')!;
  var persistenceManager =
      secondaryPersistenceStore.getHivePersistenceManager()!;
  await persistenceManager.init(storageDir);
  var hiveKeyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
  hiveKeyStore.commitLog = commitLogInstance;
  var keyStoreManager =
      secondaryPersistenceStore.getSecondaryKeyStoreManager()!;
  keyStoreManager.keyStore = hiveKeyStore;
  return keyStoreManager;
}

Future<void> tearDownFunc() async {
  await AtCommitLogManagerImpl.getInstance().close();
  var isExists = await Directory('test/hive/').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}
