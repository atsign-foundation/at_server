import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:at_persistence_secondary_server/src/utils/object_util.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

class HiveKeystore implements SecondaryKeyStore<String, AtData?, AtMetaData?> {
  final logger = AtSignLogger('HiveKeystore');

  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  var persistenceManager;
  var _commitLog;
  final _metaDataCache = HashMap();

  HiveKeystore();

  set commitLog(value) {
    _commitLog = value;
  }

  Future<void> initMetaDataCache() async {
    if (persistenceManager == null || !persistenceManager.getBox().isOpen) {
      logger.severe(
          'persistence manager not initialized. skipping metadata caching');
      return;
    }
    var keys = persistenceManager.getBox().keys;
    await Future.forEach(
        keys,
        (key) => persistenceManager.getBox().get(key).then((atData) {
              _metaDataCache[key.toString()] = atData.metaData!;
            }));
  }

  @override
  Future<AtData?> get(String key) async {
    var value;
    try {
      var hive_key = keyStoreHelper.prepareKey(key);
      value = await persistenceManager.getBox().get(hive_key);
      // load metadata for hive_key
      // compare availableAt with time.now()
      //return only between ttl and ttb
    } on Exception catch (exception) {
      logger.severe('HiveKeystore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    if (value == null) {
      throw KeyNotFoundException('$key does not exist in keystore');
    }
    return value;
  }

  @override
  Future<dynamic> put(String key, AtData? value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum}) async {
    var result;
    // Default the commit op to just the value update
    var commitOp = CommitOp.UPDATE;
    // Verifies if any of the args are not null
    var isMetadataNotNull = ObjectsUtil.isAnyNotNull(
        a1: time_to_live,
        a2: time_to_born,
        a3: time_to_refresh,
        a4: isCascade,
        a5: isBinary,
        a6: isEncrypted);
    if (isMetadataNotNull) {
      // Set commit op to UPDATE_META
      commitOp = CommitOp.UPDATE_META;
    }
    if (value != null) {
      commitOp = CommitOp.UPDATE_ALL;
    }
    try {
      // If does not exist, create a new key,
      // else update existing key.
      if (!isKeyExists(key)) {
        result = await create(key, value,
            time_to_live: time_to_live,
            time_to_born: time_to_born,
            time_to_refresh: time_to_refresh,
            isCascade: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: publicKeyChecksum);
      } else {
        var existingData = await get(key);
        var hive_key = keyStoreHelper.prepareKey(key);
        var hive_value = keyStoreHelper.prepareDataForUpdate(
            existingData!, value!,
            ttl: time_to_live,
            ttb: time_to_born,
            ttr: time_to_refresh,
            isCascade: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: publicKeyChecksum);
        logger.finest('hive key:$hive_key');
        logger.finest('hive value:$hive_value');
        await persistenceManager.getBox().put(hive_key, hive_value);
        _metaDataCache[key] = hive_value.metaData!;
        result = await _commitLog.commit(hive_key, commitOp);
      }
    } on DataStoreException {
      rethrow;
    } on Exception catch (exception) {
      logger.severe('HiveKeystore put exception: $exception');
      throw DataStoreException('exception in put: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveKeystore error: $error');
      throw DataStoreException(error.message);
    }
    return result;
  }

  @override
  Future<dynamic> create(String key, AtData? value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum}) async {
    var result;
    var commitOp;
    var hive_key = keyStoreHelper.prepareKey(key);
    var hive_data = keyStoreHelper.prepareDataForCreate(value!,
        ttl: time_to_live,
        ttb: time_to_born,
        ttr: time_to_refresh,
        isCascade: isCascade,
        isBinary: isBinary,
        isEncrypted: isEncrypted,
        dataSignature: dataSignature,
        sharedKeyEncrypted: sharedKeyEncrypted,
        publicKeyChecksum: publicKeyChecksum);
    // Default commitOp to Update.
    commitOp = CommitOp.UPDATE;

    // Setting metadata defined in values
    if (value.metaData != null) {
      time_to_live ??= value.metaData!.ttl;
      time_to_born ??= value.metaData!.ttb;
      time_to_refresh ??= value.metaData!.ttr;
      isCascade ??= value.metaData!.isCascade;
      isBinary ??= value.metaData!.isBinary;
      isEncrypted ??= value.metaData!.isEncrypted;
      dataSignature ??= value.metaData!.dataSignature;
      sharedKeyEncrypted ??= value.metaData!.sharedKeyEnc;
      publicKeyChecksum ??= value.metaData!.pubKeyCS;
    }

    // If metadata is set, set commitOp to Update all
    if (ObjectsUtil.isAnyNotNull(
        a1: time_to_live,
        a2: time_to_born,
        a3: time_to_refresh,
        a4: isCascade,
        a5: isBinary,
        a6: isEncrypted)) {
      commitOp = CommitOp.UPDATE_ALL;
    }

    try {
      await persistenceManager.getBox().put(hive_key, hive_data);
      _metaDataCache[hive_key] = hive_data.metaData!;
      result = await _commitLog.commit(hive_key, commitOp);
      return result;
    } on Exception catch (exception) {
      logger.severe('HiveKeystore create exception: $exception');
      throw DataStoreException('exception in create: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveKeystore error: $error');
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<int?> remove(String key) async {
    var result;
    try {
      await persistenceManager.getBox().delete(Utf7.encode(key));
      _metaDataCache.remove(key);
      result = await _commitLog.commit(key, CommitOp.DELETE);
      return result;
    } on Exception catch (exception) {
      logger.severe('HiveKeystore delete exception: $exception');
      throw DataStoreException('exception in remove: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveKeystore delete error: $error');
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    var result = true;
    try {
      var expiredKeys = await getExpiredKeys();
      if (expiredKeys.isNotEmpty) {
        for (var element in expiredKeys) {
          await remove(element);
        }
        result = true;
      }
    } on Exception catch (e) {
      result = false;
      logger.severe('Exception in deleteExpired keys: ${e.toString()}');
      throw DataStoreException(
          'exception in deleteExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    return result;
  }

  @override
  Future<List<String>> getExpiredKeys() async {
    var expiredKeys = <String>[];
    try {
      var now = DateTime.now().toUtc();
      if (persistenceManager.getBox() != null) {
        var keys = persistenceManager.getBox().keys;
        var expired = [];
        await Future.forEach(keys, (key) async {
          var value = await persistenceManager.getBox().get(key);
          if (value.metaData?.expiresAt != null &&
              value.metaData.expiresAt.isBefore(now)) {
            expired.add(key);
          }
        });
        expired.forEach((key) => expiredKeys.add(Utf7.encode(key)));
      }
    } on Exception catch (e) {
      logger.severe('exception in hive get expired keys:${e.toString()}');
      throw DataStoreException('exception in getExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    return expiredKeys;
  }

  /// Returns list of keys from the secondary storage.
  /// @param - regex : Optional parameter to filter keys on regular expression.
  /// @return - List<String> : List of keys from secondary storage.
  @override
  List<String> getKeys({String? regex}) {
    var keys = <String>[];
    var encodedKeys;

    try {
      if (persistenceManager.getBox() != null) {
        // If regular expression is not null or not empty, filter keys on regular expression.
        if (regex != null && regex.isNotEmpty) {
          encodedKeys = persistenceManager
              .getBox()
              .keys
              .where((element) => Utf7.decode(element).contains(RegExp(regex)));
        } else {
          encodedKeys = persistenceManager.getBox().keys.toList();
        }
        //if bool removeExpired is true, expired keys will not be added to the keys list
        encodedKeys?.forEach((key) => {
              if (_isKeyAvailable(key)) {keys.add(Utf7.decode(key))}
            });
      }
    } on FormatException catch (exception) {
      logger.severe('Invalid regular expression : $regex');
      throw InvalidSyntaxException('Invalid syntax ${exception.toString()}');
    } on Exception catch (exception) {
      logger.severe('HiveKeystore getKeys exception: ${exception.toString()}');
      throw DataStoreException('exception in getKeys: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    return keys;
  }

  @override
  Future<AtMetaData?> getMeta(String key) async {
    // try {
    //   var hive_key = keyStoreHelper.prepareKey(key);
    //   var value = await persistenceManager.getBox().get(hive_key);
    //   if (value != null) {
    //     return value.metaData;
    //   }
    // } on Exception catch (exception) {
    //   logger.severe('HiveKeystore getMeta exception: $exception');
    //   throw DataStoreException('exception in getMeta: ${exception.toString()}');
    // } on HiveError catch (error) {
    //   await _restartHiveBox(error);
    //   logger.severe('HiveKeystore getMeta error: $error');
    //   throw DataStoreException(error.message);
    // }
    // return null;
    if (_metaDataCache.containsKey(key)) {
      return _metaDataCache[key];
    }
    return null;
  }

  @override
  Future<int?> putAll(String key, AtData? value, AtMetaData? metadata) async {
    try {
      var result;
      var hive_key = keyStoreHelper.prepareKey(key);
      value!.metaData = AtMetadataBuilder(newAtMetaData: metadata).build();
      // Updating the version of the metadata.
//    (metadata!.version != null) ? metadata.version += 1 : metadata.version = 0;
      var version = metadata!.version;
      if (version != null) {
        version = version + 1;
      } else {
        version = 0;
      }
      metadata.version = version;
      await persistenceManager.getBox().put(hive_key, value);
      _metaDataCache[hive_key] = value.metaData!;
      result = await _commitLog.commit(hive_key, CommitOp.UPDATE_ALL);
      return result;
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<int?> putMeta(String key, AtMetaData? metadata) async {
    try {
      var hive_key = keyStoreHelper.prepareKey(key);
      AtData? existingData;
      if (isKeyExists(key)) {
        existingData = await get(key);
      }
      var newData = existingData ?? AtData();
      newData.metaData = AtMetadataBuilder(
              newAtMetaData: metadata, existingMetaData: newData.metaData)
          .build();
      // Updating the version of the metadata.
//    (newData.metaData?.version != null)
//        ? newData.metaData?.version += 1
//        : newData.metaData!.version = 0;

      var version = newData.metaData?.version;
      if (version != null) {
        version = version + 1;
      } else {
        version = 0;
      }
      newData.metaData?.version = version;

      await persistenceManager.getBox().put(hive_key, newData);
      _metaDataCache[hive_key] = newData.metaData!;
      var result = await _commitLog.commit(hive_key, CommitOp.UPDATE_META);
      return result;
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  /// Returns true if key exists in [HiveKeystore]; else false.
  @override
  bool isKeyExists(String key) {
    return persistenceManager
        .getBox()
        .containsKey(keyStoreHelper.prepareKey(key));
  }

  ///Restarts the hive box.
  Future<void> _restartHiveBox(Error e) async {
    // If hive box closed, reopen the box.
    if (e is HiveError && !persistenceManager.getBox().isOpen) {
      logger.info('Hive box closed. Restarting the hive box');
      await persistenceManager.openVault(persistenceManager.atsign!);
    }
  }

  bool _isExpired(key) {
    return _metaDataCache[key]!.expiresAt!.isBefore(DateTime.now().toUtc());
  }

  bool _isBorn(key) {
    return _metaDataCache[key]!.isBefore(DateTime.now().toUtc());
  }

  bool _isKeyAvailable(key) {
    return !_isExpired(key) && _isBorn(key);
  }
}
