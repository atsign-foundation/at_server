import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive/hive_keystore_helper.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_persistence_secondary_server/src/utils/object_util.dart';
import 'package:utf7/utf7.dart';

class RedisKeystore implements SecondaryKeyStore<String, AtData, AtMetaData> {
  final logger = AtSignLogger('RedisKeyStore');
  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  var persistenceManager;
  var _commitLog;

  RedisKeystore();

  set commitLog(value) {
    _commitLog = value;
  }

  @override
  Future create(String key, AtData value,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature}) async {
    var result;
    var commitOp;
    var redis_key = keyStoreHelper.prepareKey(key);
    var redis_data = keyStoreHelper.prepareDataForCreate(value,
        ttl: time_to_live,
        ttb: time_to_born,
        ttr: time_to_refresh,
        isCascade: isCascade,
        isBinary: isBinary,
        isEncrypted: isEncrypted,
        dataSignature: dataSignature);
    // Default commitOp to Update.
    commitOp = CommitOp.UPDATE;

    // Setting metadata defined in values
    if (value != null && value.metaData != null) {
      time_to_live ??= value.metaData.ttl;
      time_to_born ??= value.metaData.ttb;
      time_to_refresh ??= value.metaData.ttr;
      isCascade ??= value.metaData.isCascade;
      isBinary ??= value.metaData.isBinary;
      isEncrypted ??= value.metaData.isEncrypted;
      dataSignature ??= value.metaData.dataSignature;
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
      var value =
          (redis_data != null) ? json.encode(redis_data.toJson()) : null;

      /// milliseconds: Removes the key after specified milliseconds(time_to_live).
      await persistenceManager.redis_commands.set(redis_key, value,
          milliseconds:
              (time_to_live != null && time_to_live > 0 ? time_to_live : null));
      result = await _commitLog.commit(redis_key, commitOp);
      return result;
    } on Exception catch (exception) {
      logger.severe('RedisKeystore create exception: $exception');
      throw DataStoreException('exception in create: ${exception.toString()}');
    }
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    var result = true;
    try {
      var expiredKeys = <String>[];
      logger.info('type : ${expiredKeys.runtimeType}');
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
  Future<AtData> get(String key) async {
    var value;
    try {
      var redis_key = keyStoreHelper.prepareKey(key);
      var result = await persistenceManager.redis_commands.get(redis_key);
      if (result != null) {
        value = AtData().fromJson(json.decode(result));
      }
    } on Exception catch (exception) {
      logger.severe('RedisKeystore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    }
    return value;
  }

  @override
  Future<List<String>> getExpiredKeys() async {
    var keys = <String>[];
    try {
      var expiredKeys = <String>[];
      var now = DateTime.now().toUtc();
      if (persistenceManager.redis_commands != null) {
        var keys = await persistenceManager.redis_commands.keys('*');
        logger.info('type : ${keys.runtimeType}');
        for (var key in keys) {
          var data = await get(key);
          if (data.metaData?.expiresAt != null &&
              data.metaData.expiresAt.isBefore(now)) {
            expiredKeys.add(key);
          }
        }
      }
    } on Exception catch (e) {
      logger.severe('exception in hive get expired keys:${e.toString()}');
      throw DataStoreException('exception in getExpiredKeys: ${e.toString()}');
    }
    return keys;
  }

  @override
  Future<List<String>> getKeys({String regex}) async {
    var encodedKeys;
    try {
      if (persistenceManager.redis_commands != null) {
        // If regular expression is not null or not empty, filter keys on regular expression.
        if (regex != null && regex.isNotEmpty) {
          encodedKeys = await persistenceManager.redis_commands.keys('*');
          if (encodedKeys != null) {
            encodedKeys.retainWhere(
                (element) => Utf7.decode(element).contains(RegExp(regex)));
          }
        } else {
          encodedKeys = await persistenceManager.redis_commands.keys('*');
        }
        //encodedKeys?.forEach((key) => keys.add(Utf7.decode(key)));
      }
    } on FormatException catch (exception) {
      logger.severe('Invalid regular expression : $regex');
      throw InvalidSyntaxException('Invalid syntax ${exception.toString()}');
    } on Exception catch (exception) {
      logger.severe('RedisKeystore getKeys exception: ${exception.toString()}');
      throw DataStoreException('exception in getKeys: ${exception.toString()}');
    }
    return encodedKeys;
  }

  @override
  Future<int> put(String key, AtData value,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature}) async {
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
      assert(key != null);
      var existingData = await get(key);
      if (existingData == null) {
        result = await create(key, value,
            time_to_live: time_to_live,
            time_to_born: time_to_born,
            time_to_refresh: time_to_refresh,
            isCascade: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature);
      } else {
        var redis_key = keyStoreHelper.prepareKey(key);
        var redis_value = keyStoreHelper.prepareDataForUpdate(
            existingData, value,
            ttl: time_to_live,
            ttb: time_to_born,
            ttr: time_to_refresh,
            isCascade: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature);
        logger.finest('redis key: $redis_key');
        logger.finest('redis value: $redis_value');
        var redis_value_json =
            (redis_value != null) ? json.encode(redis_value.toJson()) : null;

        /// milliseconds: Removes the key after specified milliseconds(time_to_live).
        /// Set milliseconds if TTL value is greater than 0.
        /// If milliseconds is set to 0, key expires immediately
        await persistenceManager.redis_commands.set(redis_key, redis_value_json,
            milliseconds: (time_to_live != null && time_to_live > 0
                ? time_to_live
                : null));
        result = await _commitLog.commit(redis_key, commitOp);
      }
    } on DataStoreException {
      rethrow;
    } on Exception catch (exception) {
      logger.severe('RedisKeystore put exception: $exception');
      throw DataStoreException('exception in put: ${exception.toString()}');
    }
    return result;
  }

  @override
  Future remove(String key) async {
    var result;
    try {
      assert(key != null);
      await persistenceManager.redis_commands.del(keys: [key]);
      result = await _commitLog.commit(key, CommitOp.DELETE);
      return result;
    } on Exception catch (exception) {
      logger.severe('RedisKeystore delete exception: $exception');
      throw DataStoreException('exception in remove: ${exception.toString()}');
    }
  }

  @override
  Future<int> putAll(key, value, metadata) async {
    var result;
    var redis_key = keyStoreHelper.prepareKey(key);
    value.metaData = AtMetadataBuilder(newAtMetaData: metadata).build();
    // Updating the version of the metadata.
    (metadata.version != null) ? metadata.version += 1 : metadata.version = 0;

    /// milliseconds: Removes the key after specified milliseconds(time_to_live).
    /// Set milliseconds if TTL value is greater than 0.
    /// If milliseconds is set to 0, key expires immediately
    await persistenceManager.redis_commands?.set(redis_key, value,
        milliseconds:
            (metadata.ttl != null && metadata.ttl > 0 ? metadata.ttl : null));
    result = await _commitLog.commit(redis_key, CommitOp.UPDATE_ALL);
    return result;
  }

  @override
  Future putMeta(key, metadata) async {
    var redis_key = keyStoreHelper.prepareKey(key);
    var existingData = await get(key);
    var newData = existingData ?? AtData();
    newData.metaData = AtMetadataBuilder(
            newAtMetaData: metadata, existingMetaData: newData.metaData)
        .build();
    // Updating the version of the metadata.
    (newData.metaData.version != null)
        ? newData.metaData.version += 1
        : newData.metaData.version = 0;

    /// milliseconds: Removes the key after specified milliseconds(time_to_live).
    /// Set milliseconds if TTL value is greater than 0.
    /// If milliseconds is set to 0, key expires immediately
    await persistenceManager.redis_commands?.set(
        redis_key, json.encode(newData),
        milliseconds:
            (metadata.ttl != null && metadata.ttl > 0 ? metadata.ttl : null));
    var result = await _commitLog.commit(redis_key, CommitOp.UPDATE_META);
    return result;
  }

  @override
  Future<AtMetaData> getMeta(String key) async {
    try {
      var result;
      var redis_key = keyStoreHelper.prepareKey(key);
      var value = await persistenceManager.redis_commands?.get(redis_key);
      if (value != null) {
        var atData = json.decode(value);
        result = AtMetaData().fromJson(atData['metaData']);
        return result;
      }
    } on Exception catch (exception) {
      logger.severe('RedisKeystore getMeta exception: $exception');
      throw DataStoreException('exception in getMeta: ${exception.toString()}');
    }
    return null;
  }

  @override
  Future<List<AtData>> getValues() {
    // TODO: implement getValues
    throw UnimplementedError();
  }
}
