import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/config/configuration.dart';
import 'package:at_utils/at_logger.dart';

/// Class to configure blocklist for atConnections.
class AtConfig {
  final logger = AtSignLogger('AtConfig');

  /// Current key under which the blocklist is stored.
  final String configKey;

  final AtKeyValueStore _keyStore;
  // ignore: unused_field
  final String? _atSign;

  AtConfig(this._keyStore, this._atSign)
      : configKey = 'private:blocklist$_atSign';

  /// Returns 'success' on adding unique [blockList] into blocklist.
  Future<String> addToBlockList(Set<String> blockList) async {
    if (blockList.isEmpty) {
      throw IllegalArgumentException(
          'Provided list of atsigns to block is empty');
    }
    try {
      final existingData = await _get(configKey);
      final updated = _decodeBlockList(existingData)..addAll(blockList);
      return await _writeConfig(Configuration(updated.toList()));
    } on Exception catch (e) {
      throw DataStoreException('Failed to update blocklist: $e');
    }
  }

  /// Removes [unblockAtsignsList] from blocklist if satisfies basic conditions.
  Future<String?> removeFromBlockList(Set<String> unblockAtsignsList) async {
    if (unblockAtsignsList.isEmpty) {
      throw IllegalArgumentException(
          'Provided list of atsigns to unblock is empty');
    }
    try {
      final existingData = await _get(configKey);
      final current = _decodeBlockList(existingData);
      if (current.isEmpty) {
        return null;
      }
      final updated = current.difference(unblockAtsignsList);
      return await _writeConfig(Configuration(updated.toList()));
    } on Exception catch (e) {
      throw DataStoreException('Failed to update blocklist: $e');
    }
  }

  /// Returns blocklist by fetching from atsign's secondary.
  Future<Set<String>> getBlockList() async {
    try {
      return _decodeBlockList(await _get(configKey));
    } on Exception catch (e) {
      throw DataStoreException('Failed to fetch blocklist: $e');
    }
  }

  /// Returns 'true' if blocklist contains [atsign].
  Future<bool> checkInBlockList(String atsign) async {
    try {
      final blockList = await getBlockList();
      return blockList.contains(atsign);
    } on Exception catch (e) {
      throw DataStoreException('Failed to check blocklist: $e');
    }
  }

  Future<String> _writeConfig(Configuration config) async {
    final atData = AtData()..data = jsonEncode(config);
    logger.finest('Storing the config key:$configKey | Value: $atData');
    await _keyStore.put(configKey, atData, skipCommit: true);
    return 'success';
  }

  Set<String> _decodeBlockList(AtData? existingData) {
    if (existingData?.data == null) return <String>{};
    final config = jsonDecode(existingData!.data!);
    return Set<String>.from(config['blockList']);
  }

  /// Reads [key] from the keystore, returning `null` (rather than throwing)
  /// when the key is not present. Other failures propagate.
  Future<AtData?> _get(String key) async {
    try {
      return await _keyStore.get(key);
    } on KeyNotFoundException {
      return null;
    }
  }
}
