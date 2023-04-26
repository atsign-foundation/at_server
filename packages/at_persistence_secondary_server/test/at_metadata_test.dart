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
