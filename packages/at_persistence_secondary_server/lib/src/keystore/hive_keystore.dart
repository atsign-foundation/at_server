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
  final String expiresAt = 'expiresAt';
  final String availableAt = 'availableAt';

  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  HivePersistenceManager? persistenceManager;
  late AtCommitLog _commitLog;

  /// A map-based cache that stores "expiresAt" and "availableAt" from AtMetadata
  /// of keys with TTL or TTB set, to efficiently track the active or expired state
  /// of each key based on their respective TTB or TTL values.
  final HashMap<String, Map<String, DateTime?>> _expiryKeysCache = HashMap();

  HiveKeystore();

  @override
  set commitLog(log) {
    _commitLog = log as AtCommitLog;
  }

  @override
  get commitLog => _commitLog;

  @override
  Future<void> initialize() async {
    await _initExpiryKeysCache();
  }

  @Deprecated("Use [initialize]")

  /// Deprecated. Use [initialize]
  Future<void> init() async {
    await initialize();
  }

  Future<void> repairCommitLog() async {
    for (int commitIndex = 0;
        commitIndex < _commitLog.commitLogKeyStore.getBox().length;
        commitIndex++) {
      CommitEntry commitEntry =
          await (_commitLog.commitLogKeyStore.getBox() as LazyBox)
              .getAt(commitIndex);
      AtMetaData? atMetaData = await getMeta(commitEntry.atKey!);
      if (commitEntry.commitId != null && atMetaData?.commitId != null) {
        continue;
      } else if (commitEntry.commitId != null && atMetaData?.commitId == null) {
        await putMeta(
            commitEntry.atKey!, atMetaData?..commitId = commitEntry.commitId,
            skipCommit: true);
      } else if (commitEntry.commitId == null) {
        await _commitLog.commitLogKeyStore
            .getBox()
            .put(commitEntry.key, commitEntry..commitId = commitEntry.key);

        await putMeta(
            commitEntry.atKey!, atMetaData?..commitId = commitEntry.key,
            skipCommit: true);
      }
    }
  }

  Future<void> _initExpiryKeysCache() async {
    if (persistenceManager == null || !persistenceManager!.getBox().isOpen) {
      logger.severe(
          'persistence manager not initialized. skipping metadata caching');
      return;
    }
    logger.finest('Initializing _expiryKeysCache Map started');
    for (int index = 0; index < persistenceManager!.getBox().length; index++) {
      AtData atData =
          await (persistenceManager!.getBox() as LazyBox).getAt(index);
      _updateMetadataCache(Utf7.decode(atData.key), atData.metaData);
    }
    logger.finest('_expiryKeysCache initialization completed');
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
      String? skeEncAlgo,
      bool skipCommit = false}) async {
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
      time_to_live,
      time_to_born,
      time_to_refresh,
      isCascade,
      isBinary,
      isEncrypted,
      dataSignature,
      sharedKeyEncrypted,
      publicKeyChecksum,
      encoding,
      encKeyName,
      encAlgo,
      ivNonce,
      skeEncKeyName,
      skeEncAlgo
    });
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
            skeEncAlgo: skeEncAlgo,
            skipCommit: skipCommit);
      } else {
        AtData? existingData = await get(key);
        String hive_key = keyStoreHelper.prepareKey(key);
        var hive_value = keyStoreHelper.prepareDataForKeystoreOperation(value!,
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
        _updateMetadataCache(key, hive_value.metaData);
        int? commitId;
        if (skipCommit) {
          commitId = -1;
        } else {
          commitId = await _commitLog.commit(hive_key, commitOp,
              previousCommitId: existingData.metaData!.commitId);
        }
        await persistenceManager!
            .getBox()
            .put(hive_key, hive_value..metaData?.commitId = commitId);
        return commitId;
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
      String? skeEncAlgo,
      bool skipCommit = false}) async {
    key = key.toLowerCase();
    final atKey = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKey == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }

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
    if (ObjectsUtil.anyNotNull({
      time_to_live,
      time_to_born,
      time_to_refresh,
      isCascade,
      isBinary,
      isEncrypted,
      dataSignature,
      sharedKeyEncrypted,
      publicKeyChecksum,
      encoding,
      encKeyName,
      encAlgo,
      ivNonce,
      skeEncKeyName,
      skeEncAlgo
    })) {
      commitOp = CommitOp.UPDATE_ALL;
    }

    try {
      await persistenceManager!.getBox().put(hive_key, hive_data);
      _updateMetadataCache(key, hive_data.metaData);
      int? commitId;
      if (skipCommit) {
        commitId = -1;
      } else {
        commitId = await _commitLog.commit(hive_key, commitOp);
      }
      await persistenceManager!
          .getBox()
          .put(hive_key, hive_data..metaData?.commitId = commitId);
      return commitId;
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
  Future<int?> remove(String key, {bool skipCommit = false}) async {
    key = key.toLowerCase();
    try {
      await persistenceManager!.getBox().delete(keyStoreHelper.prepareKey(key));
      // On deleting the key, remove it from the expiryKeyCache.
      _expiryKeysCache.remove(key);
      if (skipCommit) {
        return -1;
      } else {
        return await _commitLog.commit(key, CommitOp.DELETE);
      }
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
  @server
  Future<bool> deleteExpiredKeys() async {
    bool result = true;
    try {
      List<String> expiredKeys = await getExpiredKeys();
      if (expiredKeys.isEmpty) {
        return result;
      }

      for (String element in expiredKeys) {
        try {
          await remove(element);
        } on KeyNotFoundException {
          continue;
        }
      }
      result = true;
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
    for (String key in _expiryKeysCache.keys) {
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
    if (persistenceManager == null ||
        persistenceManager?.getBox().isOpen == false) {
      throw DataStoreException(
          'Failed to fetch keys. Hive Keystore is not initialized or opened');
    }
    List<String> keys = <String>[];
    regex ??= '.*';
    RegExp regExp = RegExp(regex);
    String key;

    try {
      for (int index = 0;
          index < persistenceManager!.getBox().length;
          index++) {
        key = Utf7.decode(persistenceManager!.getBox().keyAt(index));
        try {
          if (_isKeyAvailable(key) == true && (regExp.hasMatch(key))) {
            keys.add(key);
          }
        } on FormatException catch (exception) {
          logger.severe('Invalid regular expression : $regex');
          throw InvalidSyntaxException(
              'Invalid syntax ${exception.toString()}');
        }
      }
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
    // The earlier version returns "null" when key is not present in the
    // cache map. To preserve the existing behaviour, returning "null"
    // when KeyNotFoundException is thrown.
    try {
      return (await get(key.toLowerCase()))?.metaData;
    } on KeyNotFoundException {
      return null;
    }
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
      int? commitId;
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
      _updateMetadataCache(key, value.metaData);
      commitId = await _commitLog.commit(hive_key, CommitOp.UPDATE_ALL);
      await persistenceManager!
          .getBox()
          .put(hive_key, value..metaData?.commitId = commitId);
      return commitId;
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<int?> putMeta(String key, AtMetaData? metadata,
      {bool skipCommit = false}) async {
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
      _updateMetadataCache(key, newData.metaData);
      if (skipCommit) {
        return -1;
      } else {
        int? commitId = await _commitLog.commit(hive_key, CommitOp.UPDATE_META);
        await persistenceManager!
            .getBox()
            .put(hive_key, newData..metaData?.commitId = commitId);
        return commitId;
      }
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

  /// If a key is expired, returns true; else returns false.
  bool _isExpired(key) {
    // If key is not present in _expiryKeyCache, it implies that key does not
    // have TTL set. So, the key will never expire. Return false.
    if (!_expiryKeysCache.containsKey(key) ||
        _expiryKeysCache[key]![expiresAt] == null) {
      return false;
    }
    return _expiryKeysCache[key]![expiresAt]!.isBefore(DateTime.now().toUtc());
  }

  /// Return true if the key is active
  bool _isBorn(key) {
    // If key is not present in _expiryKeyCache, it implies that key does not
    // have TTB set. So, the key will be active. Return true.
    if (!_expiryKeysCache.containsKey(key) ||
        _expiryKeysCache[key]![availableAt] == null) {
      return true;
    }
    return _expiryKeysCache[key]![availableAt]!
        .isBefore(DateTime.now().toUtc());
  }

  /// Verifies if the given key is active.
  /// If key is active, returns "true", else returns "false"
  bool _isKeyAvailable(key) {
    // If _expiryKeyCache does not contain the key, then it implies
    // that key does not have TTL or TTB set.
    // So, the key never expires; return true.
    if (!_expiryKeysCache.containsKey(key)) {
      return true;
    }
    return !_isExpired(key) && _isBorn(key);
  }

  /// Adds an entry where key is AtKey and value is Map containing the "expiresAt"
  /// and "availableAt" into the [_expiryKeysCache] map.
  ///
  /// Adds only the keys whose TTL or TTB is set in the metadata; otherwise ignored.
  void _updateMetadataCache(String key, AtMetaData? atMetaData) {
    // If the metadata of a key does not have TTL or TTB set, then the key is active forever.
    // Do not add it to _expiryKeyCache.
    if (atMetaData == null ||
        (atMetaData.ttb == null && atMetaData.ttl == null)) {
      // On an existing key, if TTL or TTB is unset, then TTL/TTB value will be null.
      // Therefore, the new metadata will not be updated in the _expiryKeyCache.
      // To prevent the stale metadata being returned from getMeta, remove the entry from
      // _expiryKeyCache
      _expiryKeysCache.remove(key);
      return;
    }
    // Setting TTL/TTB to 0 (Zero) implies to unset the metadata.
    // Therefore, the key will be active forever. Hence remove the existing key
    // (if any)from expiryKeyCache
    if ((atMetaData.ttl == null && atMetaData.ttb == 0) ||
        (atMetaData.ttb == null && atMetaData.ttl == 0)) {
      _expiryKeysCache.remove(key);
      return;
    }
    _expiryKeysCache[key] = {
      availableAt: atMetaData.availableAt,
      expiresAt: atMetaData.expiresAt
    };
  }

  @visibleForTesting
  HashMap<String, Map<String, DateTime?>> getExpiryKeysCache() {
    return _expiryKeysCache;
  }
}
