import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:hive/hive.dart';

import 'hive_access_log_keystore.dart';

/// Hive-backed implementation of [AtAccessLog] for the secondary
/// server's audit trail (from, cram, pol, lookup, plookup, pkam).
class HiveAtAccessLog implements AtAccessLog {
  late HiveAccessLogKeyStore _accessLogKeyStore;

  /// Per-pass percentage of entries to drop when compaction is
  /// invoked. Captured from `AtSecondaryConfig` at factory time;
  /// immutable per instance.
  final int compactionPercentage;

  HiveAtAccessLog(HiveAccessLogKeyStore keyValueStore,
      {this.compactionPercentage = 30}) {
    _accessLogKeyStore = keyValueStore;
  }

  ///Creates a new entry with fromAtSign, verbName and optional parameter lookupKey for lookup and plookup verbs.
  ///@param fromAtSign : The another user atsign
  ///@param verbName : The verb performed by the atsign user
  ///@param lookupKey : The optional parameter to hold lookup key when performing lookup or plookup verb.
  @override
  Future<int?> insert(String fromAtSign, String verbName,
      {String? lookupKey}) async {
    int? result;
    var entry = AccessLogEntry(fromAtSign, DateTime.now(), verbName, lookupKey);
    try {
      result = await _accessLogKeyStore.add(entry);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to access log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to access log:${e.toString()}');
    }
    return result;
  }

  @override
  Future<Map<String, int>> mostVisitedAtSigns(int length) async {
    return await _accessLogKeyStore.mostVisitedAtSigns(length);
  }

  @override
  Future<Map<String, int>> mostVisitedKeys(int length) async {
    return await _accessLogKeyStore.mostVisitedKeys(length);
  }

  @override
  int entriesCount() {
    final count = _accessLogKeyStore.entriesCount();
    return count;
  }

  @override
  int getSize() {
    return _accessLogKeyStore.getSize();
  }

  @override
  Future<AccessLogEntry> getLastAccessLogEntry() async {
    return await _accessLogKeyStore.getLastEntry();
  }

  @override
  Future<AccessLogEntry?> getLastPkamAccessLogEntry() async {
    return await _accessLogKeyStore.getLastPkamEntry();
  }

  @override
  Stream<AccessLogEntry> iterate() async* {
    // Access log uses a LazyBox; fetch each value asynchronously
    // through the keystore's typed get, in insertion (key) order.
    final keys = _accessLogKeyStore.getBox().keys.toList();
    keys.sort((a, b) => (a as int).compareTo(b as int));
    for (final key in keys) {
      final entry = await _accessLogKeyStore.get(key as int);
      if (entry != null) yield entry;
    }
  }

  ///Closes the [accessLogKeyStore] instance.
  @override
  Future<void> close() async {
    await _accessLogKeyStore.close();
  }

  /// Drop every entry from the underlying box without closing it.
  /// Used by [AtPersistenceBundle.clear] for cheap test isolation.
  Future<void> clear() async {
    await _accessLogKeyStore.getBox().clear();
  }

  /// Compact the access log. Drops the oldest
  /// [compactionPercentage] of entries by insertion order.
  @override
  Stream<int> compact(bool dryRun) async* {
    final int totalKeys = entriesCount();
    final int firstN = (totalKeys * (compactionPercentage / 100)).toInt();
    final List<int> keysToDelete = _accessLogKeyStore.getFirstNEntries(firstN);
    if (dryRun) {
      for (final id in keysToDelete) {
        yield id;
      }
      return;
    }
    try {
      await _accessLogKeyStore.removeAll(keysToDelete);
    } on Exception catch (e) {
      throw DataStoreException(
          'DataStoreException while deleting for compaction:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error while deleting for compaction:${e.toString()}');
    }
    for (final id in keysToDelete) {
      yield id;
    }
  }

  @override
  String toString() {
    return runtimeType.toString();
  }
}
