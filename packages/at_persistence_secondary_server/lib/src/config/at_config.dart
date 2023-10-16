import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/config/configuration.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

/// Class to configure blocklist for atconnections.
class AtConfig {
  var logger = AtSignLogger('AtConfig');

  ///stores 'Configuration' type under [configkey] in secondary.
  String olConfigKey = 'configKey';
  String configKey = 'private:blocklist';
  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  final String? _atSign;
  AtCommitLog? _commitLog;
  late HivePersistenceManager persistenceManager;

  void init(AtCommitLog commitLog) {
    _commitLog = commitLog;
  }

  AtConfig(this._commitLog, this._atSign) {
    persistenceManager = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(_atSign)!
        .getHivePersistenceManager()!;
  }

  ///Returns 'success' on adding unique [blockList] into blocklist.
  Future<String> addToBlockList(Set<String> blockList) async {
    String result;
    try {
      assert(blockList.isNotEmpty);
      AtData? existingData = await _getExistingData();
      Set<String> uniqueBlockList = await getBlockList();
      uniqueBlockList.addAll(blockList);
      var config = Configuration(List<String>.from(uniqueBlockList));
      result = await prepareAndStoreData(config, existingData);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    return result;
  }

  ///removes [unblockAtsignsList] from blocklist if satisfies basic conditions.
  Future<String?> removeFromBlockList(Set<String> unblockAtsignsList) async {
    String? result;
    try {
      assert(unblockAtsignsList.isNotEmpty);
      var existingData = await _getExistingData();
      Set<String> blockedAtsignsSet = await getBlockList();
      // remove the atsign in unblockAtsignList from the existing blocklist
      if (blockedAtsignsSet.isNotEmpty) {
        var config = Configuration(
            List.from(blockedAtsignsSet.difference(Set.from(unblockAtsignsList))));
        result = await prepareAndStoreData(config, existingData);
      }
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException('Hive error adding to commit log:${e.message}');
    }
    return result;
  }

  ///Returns blocklist by fetching from atsign's secondary.
  Future<Set<String>> getBlockList() async {
    var result = <String>{};
    try {
      var existingData = await _getExistingData();
      if (existingData != null) {
        var config = jsonDecode(existingData.data!);
        result = Set<String>.from(config['blockList']);
      }
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }

    return result;
  }

  ///Returns [AtData] value for given [key].
  Future<AtData?> get(String key) async {
    AtData? value;
    try {
      var hiveKey = keyStoreHelper.prepareKey(key);
      value = await (persistenceManager.getBox() as LazyBox).get(hiveKey);
    } on Exception catch (exception) {
      logger.severe('HiveKeystore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveKeystore get error: $error');
      throw DataStoreException(error.message);
    }

    return value;
  }

  ///Returns 'true' if blocklist contains [atsign].
  Future<bool> checkInBlockList(String atsign) async {
    var result = false;
    try {
      var blockList = await getBlockList();
      result = blockList.contains(atsign);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    return result;
  }

  ///Returns 'success' after successfully persisting data into secondary.
  Future<String> prepareAndStoreData(config, [existingData]) async {
    String result;
    configKey = keyStoreHelper.prepareKey(configKey);
    var newData = AtData();
    newData.data = jsonEncode(config);

    newData = keyStoreHelper.prepareDataForKeystoreOperation(newData,
        existingAtData: existingData);

    logger.finest('Storing the config key:$configKey | Value: $newData');
    await persistenceManager.getBox().put(configKey, newData);
    await _commitLog!.commit(configKey, CommitOp.UPDATE);
    result = 'success';
    return result;
  }

  /// Fetches existing Config data from the keystore
  ///
  /// Tries fetching data with [configKey] which is the new config key
  ///
  /// For backward-compatability, if data could not be fetched with new key
  /// tries fetching data with [oldConfigKey]
  Future<AtData?> _getExistingData() async {
    AtData? existingData;
    try {
      // try to fetch data using the new config-key format
      existingData = await get(configKey);
    } on KeyNotFoundException catch (e) {
      logger.finer('Could not fetch data with NEW config-key | ${e.message}');
    }
    if (existingData == null) {
      try {
        existingData = await get(olConfigKey);
        await (persistenceManager.getBox() as LazyBox).delete(olConfigKey);
      } on KeyNotFoundException catch (e) {
        logger.finer('Could not fetch data with OLD config-key | ${e.message}');
      }
    }
    return existingData;
  }
}
