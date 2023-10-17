import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/config/configuration.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

/// Class to configure blocklist for atConnections.
class AtConfig {
  var logger = AtSignLogger('AtConfig');

  ///stores 'Configuration' type under [configKey] in secondary.
  final oldConfigKey = HiveKeyStoreHelper.getInstance().prepareKey('configKey');
  final configKey =
      HiveKeyStoreHelper.getInstance().prepareKey('private:blocklist');
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
    String? result;
    if (blockList.isEmpty) {
      throw IllegalArgumentException(
          'Provided list of atsigns to block is empty');
    }
    try {
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

  /// Removes [unblockAtsignsList] from blocklist if satisfies basic conditions.
  Future<String?> removeFromBlockList(Set<String> unblockAtsignsList) async {
    String? result;
    if (unblockAtsignsList.isEmpty) {
      throw IllegalArgumentException(
          'Provided list of atsigns to unblock is empty');
    }
    try {
      var existingData = await _getExistingData();
      Set<String> blockedAtsignsSet = await getBlockList();
      // remove the atsign in unblockAtsignList from the existing blockedAtsignsSet
      if (blockedAtsignsSet.isNotEmpty) {
        var config = Configuration(List.from(
            blockedAtsignsSet.difference(Set.from(unblockAtsignsList))));
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
    var blockList = <String>{};
    try {
      var existingData = await _getExistingData();
      if (existingData != null && existingData.data != null) {
        var config = jsonDecode(existingData.data!);
        blockList = Set<String>.from(config['blockList']);
      }
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    return blockList;
  }

  ///Returns [AtData] value for given [key].
  Future<AtData?> get(String key) async {
    AtData? value;
    try {
      value = await (persistenceManager.getBox() as LazyBox).get(key);
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
    var newData = AtData();
    newData.data = jsonEncode(config);

    newData = HiveKeyStoreHelper.getInstance()
        .prepareDataForKeystoreOperation(newData, existingAtData: existingData);

    logger.finest('Storing the config key:$configKey | Value: $newData');
    await persistenceManager.getBox().put(configKey, newData);
    await _commitLog!.commit(configKey, CommitOp.UPDATE);
    return 'success';
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
    } on Exception catch (e) {
      logger.finer('Could not fetch data with NEW config-key | $e');
      rethrow;
    }
    if (existingData == null) {
      // If data could not be fetched with the new config-key, try fetching the data
      // using the old config-key and delete the old key from keystore
      try {
        existingData = await get(oldConfigKey);
        if (existingData != null && existingData.data != null) {
          AtData newAtData = AtData()..data = existingData.data;
          HiveKeyStoreHelper.getInstance().prepareDataForKeystoreOperation(
              newAtData,
              existingAtData: existingData);
          // store the existing data with the new key
          await persistenceManager.getBox().put(configKey, newAtData);
          logger.info('Successfully migrated configKey data to new key format');
          await persistenceManager.getBox().delete(oldConfigKey);
        }
      } on KeyNotFoundException catch (e) {
        logger.finer('Could not fetch data with OLD config-key | ${e.message}');
      } on Exception catch (e) {
        logger.finer('Could not fetch data with OLD config-key | $e');
        rethrow;
      }
    }
    return existingData;
  }
}
