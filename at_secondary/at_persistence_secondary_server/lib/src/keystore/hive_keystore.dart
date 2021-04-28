import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_secondary_server/src/model/at_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_meta_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_metadata_builder.dart';
import 'package:at_persistence_secondary_server/src/utils/object_util.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';
import 'package:utf7/utf7.dart';

class HiveKeystore implements SecondaryKeyStore<String, AtData, AtMetaData> {
  final logger = AtSignLogger('HiveKeystore');

  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  var persistenceManager;
  var _commitLog;

  HiveKeystore();

  set commitLog(value) {
    _commitLog = value;
  }

  @override
  Future<AtData> get(String key) async {
    var value;
    try {
      var hive_key = keyStoreHelper.prepareKey(key);
      value = await persistenceManager.box?.get(hive_key);
      // load metadata for hive_key
      // compare availableAt with time.now()
      //return only between ttl and ttb
    } on Exception catch (exception) {
      logger.severe('HiveKeystore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: ${error}');
      throw DataStoreException(error.message);
    }
    return value;
  }

  @override
  Future<int> put(String key, AtData value, {Metadata metadata}) async {
    var result;
    // Default the commit op to just the value update
    var commitOp = CommitOp.UPDATE;
    // Verifies if any of the args are not null
    var isMetadataNotNull = (metadata != null) &&
        ObjectsUtil.isAnyNotNull(
            a1: metadata.ttl,
            a2: metadata.ttb,
            a3: metadata.ttr,
            a4: metadata.ccd,
            a5: metadata.isBinary,
            a6: metadata.isEncrypted,
            a7: metadata.sharedKeyStatus);
    if (isMetadataNotNull) {
      // Set commit op to UPDATE_META
      commitOp = CommitOp.UPDATE_META;
    }
    if (value != null) {
      commitOp = CommitOp.UPDATE_ALL;
    }
    try {
      assert(key != null);
      var existingData = await get(key);
      if (existingData == null) {
        result = await create(key, value, metadata: metadata);
      } else {
        var hive_key = keyStoreHelper.prepareKey(key);
        var hive_value = keyStoreHelper.prepareDataForUpdate(
            existingData, value,
            ttl: metadata?.ttl,
            ttb: metadata?.ttb,
            ttr: metadata?.ttr,
            isCascade: metadata?.isCached,
            isBinary: metadata?.isBinary,
            isEncrypted: metadata?.isEncrypted,
            dataSignature: metadata?.dataSignature);
        logger.finest('hive key:${hive_key}');
        logger.finest('hive value:${hive_value}');
        await persistenceManager.box?.put(hive_key, hive_value);
        result = await _commitLog.commit(hive_key, commitOp);
      }
    } on DataStoreException {
      rethrow;
    } on Exception catch (exception) {
      logger.severe('HiveKeystore put exception: $exception');
      throw DataStoreException('exception in put: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore error: $error');
      throw DataStoreException(error.message);
    }
    return result;
  }

  @override
  Future<int> create(String key, AtData value, {Metadata metadata}) async {
    var result;
    var commitOp;
    var hive_key = keyStoreHelper.prepareKey(key);
    var hive_data = keyStoreHelper.prepareDataForCreate(value,
        ttl: metadata?.ttl,
        ttb: metadata?.ttb,
        ttr: metadata?.ttr,
        isCascade: metadata?.isCached,
        isBinary: metadata?.isBinary,
        isEncrypted: metadata?.isEncrypted,
        dataSignature: metadata?.dataSignature,
        sharedKeyStatus: metadata?.sharedKeyStatus);
    // Default commitOp to Update.
    commitOp = CommitOp.UPDATE;

    // Setting metadata defined in values
    if (value != null && value.metaData != null) {
      metadata.ttl ??= value.metaData.ttl;
      metadata.ttb ??= value.metaData.ttb;
      metadata.ttr ??= value.metaData.ttr;
      metadata.ccd ??= value.metaData.isCascade;
      metadata.isBinary ??= value.metaData.isBinary;
      metadata.isEncrypted ??= value.metaData.isEncrypted;
      metadata.dataSignature ??= value.metaData.dataSignature;
      metadata.sharedKeyStatus ??= value.metaData.sharedKeyStatus;
    }

    // If metadata is set, set commitOp to Update all
    if (metadata != null &&
        ObjectsUtil.isAnyNotNull(
            a1: metadata.ttl,
            a2: metadata.ttb,
            a3: metadata.ttr,
            a4: metadata.ccd,
            a5: metadata.isBinary,
            a6: metadata.isEncrypted,
        a7: metadata.sharedKeyStatus)) {
      commitOp = CommitOp.UPDATE_ALL;
    }

    try {
      await persistenceManager.box?.put(hive_key, hive_data);
      result = await _commitLog.commit(hive_key, commitOp);
      return result;
    } on Exception catch (exception) {
      logger.severe('HiveKeystore create exception: $exception');
      throw DataStoreException('exception in create: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore error: $error');
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<int> remove(String key) async {
    var result;
    try {
      assert(key != null);
      await persistenceManager.box?.delete(Utf7.encode(key));
      result = await _commitLog.commit(key, CommitOp.DELETE);
      return result;
    } on Exception catch (exception) {
      logger.severe('HiveKeystore delete exception: $exception');
      throw DataStoreException('exception in remove: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore delete error: $error');
      throw DataStoreException(error.message);
    }
  }

  @override
  bool deleteExpiredKeys() {
    var result = true;
    try {
      var expiredKeys = getExpiredKeys();
      if (expiredKeys.isNotEmpty) {
        expiredKeys.forEach((element) {
          remove(element);
        });
        result = true;
      }
    } on Exception catch (e) {
      result = false;
      logger.severe('Exception in deleteExpired keys: ${e.toString()}');
      throw DataStoreException(
          'exception in deleteExpiredKeys: ${e.toString()}');
    }
    return result;
  }

  @override
  List<String> getExpiredKeys() {
    var expiredKeys = <String>[];
    try {
      var now = DateTime.now().toUtc();
      if (persistenceManager.box != null) {
        var expired = persistenceManager.box.values
            .where((data) =>
                data.metaData?.expiresAt != null &&
                data.metaData.expiresAt.isBefore(now))
            .toList();
        expired?.forEach((entry) => expiredKeys.add(Utf7.encode(entry.key)));
      }
    } on Exception catch (e) {
      logger.severe('exception in hive get expired keys:${e.toString()}');
      throw DataStoreException('exception in getExpiredKeys: ${e.toString()}');
    }
    return expiredKeys;
  }

  /// Returns list of keys from the secondary storage.
  /// @param - regex : Optional parameter to filter keys on regular expression.
  /// @return - List<String> : List of keys from secondary storage.
  @override
  List<String> getKeys({String regex}) {
    var keys = <String>[];
    var encodedKeys;

    try {
      if (persistenceManager.box != null) {
        // If regular expression is not null or not empty, filter keys on regular expression.
        if (regex != null && regex.isNotEmpty) {
          encodedKeys = persistenceManager.box.keys
              .where((element) => Utf7.decode(element).contains(RegExp(regex)));
        } else {
          encodedKeys = persistenceManager.box.keys.toList();
        }
        encodedKeys?.forEach((key) => keys.add(Utf7.decode(key)));
      }
    } on FormatException catch (exception) {
      logger.severe('Invalid regular expression : ${regex}');
      throw InvalidSyntaxException('Invalid syntax ${exception.toString()}');
    } on Exception catch (exception) {
      logger.severe('HiveKeystore getKeys exception: ${exception.toString()}');
      throw DataStoreException('exception in getKeys: ${exception.toString()}');
    }
    return keys;
  }

  @override
  Future<AtMetaData> getMeta(String key) async {
    try {
      var hive_key = keyStoreHelper.prepareKey(key);
      var value = await persistenceManager.box?.get(hive_key);
      if (value != null) {
        return value.metaData;
      }
    } on Exception catch (exception) {
      logger.severe('HiveKeystore getMeta exception: $exception');
      throw DataStoreException('exception in getMeta: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore getMeta error: ${error}');
      throw DataStoreException(error.message);
    }
    return null;
  }

  @override
  Future<int> putAll(String key, AtData value, AtMetaData metadata) async {
    var result;
    var hive_key = keyStoreHelper.prepareKey(key);
    value.metaData = AtMetadataBuilder(newAtMetaData: metadata).build();
    // Updating the version of the metadata.
    (metadata.version != null) ? metadata.version += 1 : metadata.version = 0;
    await persistenceManager.box?.put(hive_key, value);
    result = await _commitLog.commit(hive_key, CommitOp.UPDATE_ALL);
    return result;
  }

  @override
  Future<int> putMeta(String key, AtMetaData metadata) async {
    var hive_key = keyStoreHelper.prepareKey(key);
    var existingData = await get(key);
    var newData = existingData ?? AtData();
    newData.metaData = AtMetadataBuilder(
            newAtMetaData: metadata, existingMetaData: newData.metaData)
        .build();
    // Updating the version of the metadata.
    (newData.metaData.version != null)
        ? newData.metaData.version += 1
        : newData.metaData.version = 0;
    await persistenceManager.box?.put(hive_key, newData);
    var result = await _commitLog.commit(hive_key, CommitOp.UPDATE_META);
    return result;
  }
}
