// ignore_for_file: non_constant_identifier_names

import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:at_persistence_secondary_server/src/utils/object_util.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

class HiveKeystore implements SecondaryKeyStore<String, AtData?, AtMetaData?> {
  final AtSignLogger logger = AtSignLogger('HiveKeystore');

  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  HivePersistenceManager? persistenceManager;
  late AtCommitLog _commitLog;
  final HashMap<String, AtMetaData?> _metaDataCache = HashMap();

  HiveKeystore();

  @override
  set commitLog(log) {
    _commitLog = log as AtCommitLog;
  }

  @override
  get commitLog => _commitLog;

  @override
  Future<void> initialize() async {
    await _initMetaDataCache();
  }

  @Deprecated("Use [initialize]")
  /// Deprecated. Use [initialize]
  Future<void> init() async {
    await initialize();
  }

  Future<void> _initMetaDataCache() async {
    if (persistenceManager == null || !persistenceManager!.getBox().isOpen) {
      logger.severe(
          'persistence manager not initialized. skipping metadata caching');
      return;
    }
    logger.finest('Metadata cache initialization started');
    var keys = _getKeysFromKeyStore();
    await Future.forEach(
        keys,
        (key) => get(key.toString()).then((atData) {
              _metaDataCache[key.toString()] = atData?.metaData;
            }));
    logger.finest('Metadata cache initialization complete');
  }

  @override
  Future<AtData?> get(String key) async {
    key = key.toLowerCase();
    AtData? value;
    try {
      String hiveKey = keyStoreHelper.prepareKey(key);
      value = await (persistenceManager!.getBox() as LazyBox).get(hiveKey);
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
      throw KeyNotFoundException('$key does not exist in keystore',
          intent: Intent.fetchData,
          exceptionScenario: ExceptionScenario.keyNotFound);
    }
    return value;
  }

  /// hive does not support directly storing emoji characters. So keys are encoded in [HiveKeyStoreHelper.prepareKey] using utf7 before storing.
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
      String? publicKeyChecksum,
      String? encoding,
      String? encKeyName,
      String? encAlgo,
      String? ivNonce,
      String? skeEncKeyName,
      String? skeEncAlgo}) async {
    key = key.toLowerCase();
    final atKey = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKey == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }
    // ignore: prefer_typing_uninitialized_variables
    var result;
    // Default the commit op to just the value update
    CommitOp commitOp = CommitOp.UPDATE;

    // Set CommitOp to UPDATE_META if any of the metadata args are not null
    var hasNonNullMetadata = ObjectsUtil.anyNotNull({
      time_to_live,time_to_born,time_to_refresh,
      isCascade,isBinary,isEncrypted,
      dataSignature, sharedKeyEncrypted, publicKeyChecksum, encoding,
      encKeyName, encAlgo, ivNonce, skeEncKeyName, skeEncAlgo});
    if (hasNonNullMetadata) {
      commitOp = CommitOp.UPDATE_META;
    }
    // But if the value is not null, the CommitOp will always  be UPDATE_ALL
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
            publicKeyChecksum: publicKeyChecksum,
            encoding: encoding,
            encKeyName: encKeyName,
            encAlgo: encAlgo,
            ivNonce: ivNonce,
            skeEncKeyName: skeEncKeyName,
            skeEncAlgo: skeEncAlgo);
      } else {
        AtData? existingData = await get(key);
        String hive_key = keyStoreHelper.prepareKey(key);
        var hive_value = keyStoreHelper.prepareDataForKeystoreOperation(
            value!,
            existingAtData: existingData!,
            ttl: time_to_live,
            ttb: time_to_born,
            ttr: time_to_refresh,
            isCascade: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: publicKeyChecksum,
            encoding: encoding,
            encKeyName: encKeyName,
            encAlgo: encAlgo,
            ivNonce: ivNonce,
            skeEncKeyName: skeEncKeyName,
            skeEncAlgo: skeEncAlgo,
            atSign: persistenceManager?.atsign);
        logger.finest('hive key:$hive_key');
        logger.finest('hive value:$hive_value');
        await persistenceManager!.getBox().put(hive_key, hive_value);
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

  /// hive does not support directly storing emoji characters. So keys are encoded in [HiveKeyStoreHelper.prepareKey] using utf7 before storing.
  @override
  @server
  Future<dynamic> create(String key, AtData? value,
      {int? time_to_live,
      int? time_to_born,
      int? time_to_refresh,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum,
      String? encoding,
      String? encKeyName,
      String? encAlgo,
      String? ivNonce,
      String? skeEncKeyName,
      String? skeEncAlgo}) async {
    key = key.toLowerCase();
    final atKey = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKey == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }

    int? result;
    CommitOp commitOp;
    String hive_key = keyStoreHelper.prepareKey(key);
    var hive_data = keyStoreHelper.prepareDataForKeystoreOperation(value!,
        atSign: persistenceManager?.atsign,
        ttl: time_to_live,
        ttb: time_to_born,
        ttr: time_to_refresh,
        isCascade: isCascade,
        isBinary: isBinary,
        isEncrypted: isEncrypted,
        dataSignature: dataSignature,
        sharedKeyEncrypted: sharedKeyEncrypted,
        publicKeyChecksum: publicKeyChecksum,
        encoding: encoding,
        encKeyName: encKeyName,
        encAlgo: encAlgo,
        ivNonce: ivNonce,
        skeEncKeyName: skeEncKeyName,
        skeEncAlgo: skeEncAlgo);
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
      encoding ??= value.metaData!.encoding;
      encKeyName ??= value.metaData!.encKeyName;
      encAlgo ??= value.metaData!.encAlgo;
      ivNonce ??= value.metaData!.ivNonce;
      skeEncKeyName ??= value.metaData!.skeEncKeyName;
      skeEncAlgo ??= value.metaData!.skeEncAlgo;
    }

    // Set CommitOp to UPDATE_ALL if any of the metadata args are not null
    if (ObjectsUtil.anyNotNull({time_to_live,time_to_born,time_to_refresh,
      isCascade,isBinary,isEncrypted,
      dataSignature, sharedKeyEncrypted, publicKeyChecksum, encoding,
      encKeyName, encAlgo, ivNonce, skeEncKeyName, skeEncAlgo})) {
      commitOp = CommitOp.UPDATE_ALL;
    }

    try {
      await persistenceManager!.getBox().put(hive_key, hive_data);
      _metaDataCache[key] = hive_data.metaData!;
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

  /// Returns an integer if the key to be deleted is present in keystore or cache.
  @override
  Future<int?> remove(String key) async {
    key = key.toLowerCase();
    int? result;
    try {
      await persistenceManager!.getBox().delete(keyStoreHelper.prepareKey(key));
      _removeKeyFromMetadataCache(key);
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

  AtMetaData? _removeKeyFromMetadataCache(String key) {
    final removeResult = _metaDataCache.remove(key);
    logger.finer('remove result for key $key is $removeResult');
    return removeResult;
  }

  @override
  @server
  Future<bool> deleteExpiredKeys() async {
    bool result = true;
    try {
      List<String> expiredKeys = await getExpiredKeys();
      if (expiredKeys.isNotEmpty) {
        for (String element in expiredKeys) {
          try {
            await remove(element);
          } on KeyNotFoundException {
            continue;
          }
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
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    return result;
  }

  @override
  @server
  Future<List<String>> getExpiredKeys() async {
    List<String> expiredKeys = <String>[];
    for (String key in _metaDataCache.keys) {
      if (_isExpired(key)) {
        expiredKeys.add(key);
      }
    }
    return expiredKeys;
  }

  /// Returns list of keys from the secondary storage.
  /// @param - regex : Optional parameter to filter keys on regular expression.
  /// @return - List<String> : List of keys from secondary storage.
  @override
  List<String> getKeys({String? regex}) {
    List<String> keys = <String>[];
    // ignore: prefer_typing_uninitialized_variables
    var keysFromKeystore;

    try {
      // ignore: unnecessary_null_comparison
      if (persistenceManager!.getBox() != null) {
        // If regular expression is not null or not empty, filter keys on regular expression.
        if (regex != null && regex.isNotEmpty) {
          keysFromKeystore = _getKeysFromKeyStore()
              .where((element) => element.contains(RegExp(regex)));
        } else {
          keysFromKeystore = _getKeysFromKeyStore().toList();
        }
        //if bool removeExpired is true, expired keys will not be added to the keys list
        keysFromKeystore?.forEach((key) => {
              if (_isKeyAvailable(key)) {keys.add(key)}
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
    key = key.toLowerCase();
    return _metaDataCache[key];
  }

  @override
  @client
  Future<int?> putAll(String key, AtData? value, AtMetaData? metadata) async {
    key = key.toLowerCase();
    final atKeyType = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKeyType == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }
    try {
      int? result;
      String hive_key = keyStoreHelper.prepareKey(key);
      AtData? existingData;
      if (isKeyExists(key)) {
        existingData = await get(key);
      }
      value!.metaData = AtMetadataBuilder(
              newAtMetaData: metadata,
              existingMetaData: existingData?.metaData,
              atSign: persistenceManager?.atsign)
          .build();
      await persistenceManager!.getBox().put(hive_key, value);
      _metaDataCache[key] = value.metaData!;
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
    key = key.toLowerCase();
    try {
      String hive_key = keyStoreHelper.prepareKey(key);
      AtData? existingData;
      if (isKeyExists(key)) {
        existingData = await get(key);
      }
      // putMeta is intended to updates only the metadata of a key.
      // So, fetch the value from the existing key and set the same value.
      AtData newData = existingData ?? AtData();
      newData.metaData = AtMetadataBuilder(
              newAtMetaData: metadata,
              existingMetaData: existingData?.metaData,
              atSign: persistenceManager?.atsign)
          .build();

      await persistenceManager!.getBox().put(hive_key, newData);
      _metaDataCache[hive_key] = newData.metaData!;
      var result = await _commitLog.commit(hive_key, CommitOp.UPDATE_META);
      return result;
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  /// Returns true if key exists in [HiveKeystore]. false otherwise.
  @override
  @server
  bool isKeyExists(String key) {
    key = key.toLowerCase();
    return persistenceManager!
        .getBox()
        .containsKey(keyStoreHelper.prepareKey(key));
  }

  ///Restarts the hive box.
  Future<void> _restartHiveBox(Error e) async {
    // If hive box closed, reopen the box.
    if (e is HiveError && !persistenceManager!.getBox().isOpen) {
      logger.info('Hive box closed. Restarting the hive box');
      await persistenceManager!
          .openBox(AtUtils.getShaForAtSign(persistenceManager!.atsign!));
    }
  }

  /// hive keys are stored in utf7 encoded format. Decode the keys while fetching
  Iterable<String> _getKeysFromKeyStore() {
    return persistenceManager!.getBox().keys.map((e) => Utf7.decode(e));
  }

  bool _isExpired(key) {
    if (_metaDataCache[key]?.expiresAt == null) {
      return false;
    }
    return _metaDataCache[key]!.expiresAt!.isBefore(DateTime.now().toUtc());
  }

  bool _isBorn(key) {
    if (_metaDataCache[key]!.availableAt == null) {
      return true;
    }
    return _metaDataCache[key]!.availableAt!.isBefore(DateTime.now().toUtc());
  }

  bool _isKeyAvailable(key) {
    if (_metaDataCache.containsKey(key)) {
      return !_isExpired(key) && _isBorn(key);
    } else {
      return false;
    }
  }

  @visibleForTesting
  HashMap<String, AtMetaData?> getMetaDataCache() {
    return _metaDataCache;
  }
}
