import 'dart:convert';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/config/configuration.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive/hive_keystore_helper.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store_factory.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

/// Class to configure blocklist for atconnections.
class AtConfig {
  var logger = AtSignLogger('AtConfig');

  ///stores 'Configuration' type under [configkey] in secondary.
  String configKey = 'configKey';
  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  final _atSign;
  var _commitLog;
  var persistenceManager;
  var _keyStore;

  void init(AtCommitLog commitLog) {
    _commitLog = commitLog;
  }

  AtConfig(this._commitLog, this._atSign, String keyStore) {
    persistenceManager = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(_atSign)
        .getPersistenceManager();
    _keyStore = keyStore;
  }

  ///Returns 'success' on adding unique [data] into blocklist.
  Future<String> addToBlockList(Set<String> data) async {
    var result;
    try {
      assert(data != null);
      assert(data.isNotEmpty);

      var existingData = await get(configKey);
      var blockList = await getBlockList();
      var uniqueBlockList = Set.from(blockList ?? []);
      uniqueBlockList.addAll(data);
      var config = Configuration(List<String>.from(uniqueBlockList));
      result = await prepareAndStoreData(config, existingData);
      return result;
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
  }

  ///removes [data] from blocklist if satisfies basic conditions.
  Future<String> removeFromBlockList(Set<String> data) async {
    var result;
    try {
      assert(data != null);
      assert(data.isNotEmpty);

      var existingData = await get(configKey);
      if (existingData != null) {
        var blockList = await getBlockList();
        var config = Configuration(
            List.from(Set.from(blockList).difference(Set.from(data))));
        result = await prepareAndStoreData(config, existingData);
      }
      return result;
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
  }

  ///Returns blocklist by fetching from atsign's secondary.
  Future<Set<String>> getBlockList() async {
    Set<String> result;
    try {
      var existingData = await get(configKey);
      if (existingData != null) {
        var config = jsonDecode(existingData.data);
        result = Set<String>.from(config['blockList']);
      }
      return result;
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
  }

  ///Returns [AtData] value for given [key].
  Future<AtData> get(String key) async {
    var value;
    try {
      var hive_key = keyStoreHelper.prepareKey(key);
      if (_keyStore == 'redis') {
        value = await persistenceManager.redis_commands?.get(hive_key);
      } else {
        value = await persistenceManager.box?.get(hive_key);
      }
      return value;
    } on Exception catch (exception) {
      logger.severe('HiveKeystore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      throw DataStoreException(error.message);
    }
  }

  ///Returns 'true' if blocklist contains [atsign].
  Future<bool> checkInBlockList(String atsign) async {
    var result = false;
    try {
      var blockList = await getBlockList();
      result = blockList?.contains(atsign) ?? result;
      return result;
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
  }

  ///Returns 'success' after successfully persisiting data into secondary.
  Future<String> prepareAndStoreData(config, [existingData]) async {
    var result;
    configKey = keyStoreHelper.prepareKey(configKey);
    var newData = AtData();
    newData.data = jsonEncode(config);
    if (existingData == null) {
      newData = keyStoreHelper.prepareDataForCreate(newData);
    } else {
      newData = keyStoreHelper.prepareDataForUpdate(existingData, newData);
    }
    logger.finest('config key:$configKey');
    logger.finest('config value:$newData');
    await SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(_atSign)
        .getSecondaryKeyStore()
        .put(configKey, newData);
    await _commitLog.commit(configKey, CommitOp.UPDATE);
    result = 'success';
    return result;
  }
}
