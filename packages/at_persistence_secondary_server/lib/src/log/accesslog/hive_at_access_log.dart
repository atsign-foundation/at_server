import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_log_keystore.dart';
import 'package:hive/hive.dart';

/// Hive-backed implementation of [AtAccessLog] for the secondary
/// server's audit trail (from, cram, pol, lookup, plookup, pkam).
class HiveAtAccessLog implements AtAccessLog {
  // ignore: prefer_typing_uninitialized_variables
  late AccessLogKeyStore _accessLogKeyStore;

  late AtCompactionConfig atCompactionConfig;

  HiveAtAccessLog(AccessLogKeyStore keyStore) {
    _accessLogKeyStore = keyStore;
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

  ///The functions returns the top [length] visited atSign's.
  ///@param - length : The maximum number of atsign's to return
  ///@return Map : Returns a key value pair. Key is the atsign and value is the count of number of times the atsign is looked at.
  @override
  Future<Map>? mostVisitedAtSigns(int length) async {
    return await _accessLogKeyStore.mostVisitedAtSigns(length);
  }

  ///The functions returns the top [length] visited atKey's.
  ///@param length : The recent number of keys to fetch
  ///@return Map : Returns a key value pair. Key is the atsign key looked up and
  ///value is number of times the key is looked up.
  @override
  Future<Map>? mostVisitedKeys(int length) async {
    return await _accessLogKeyStore.mostVisitedKeys(length);
  }

  @override
  int entriesCount() {
    final count = _accessLogKeyStore.entriesCount();
    return count;
  }

  @override
  Future<void> deleteKeyForCompaction(List<int> keysList) async {
    try {
      await _accessLogKeyStore.removeAll(keysList);
    } on Exception catch (e) {
      throw DataStoreException(
          'DataStoreException while deleting for compaction:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error while deleting for compaction:${e.toString()}');
    }
  }

  @override
  Future<List<int>> getKeysToDeleteOnCompaction() async {
    int totalKeys = entriesCount();
    int firstNKeys =
        (totalKeys * (atCompactionConfig.compactionPercentage! / 100)).toInt();
    try {
      return _accessLogKeyStore.getFirstNEntries(firstNKeys);
    } on Exception catch (e) {
      throw DataStoreException(
          'DataStoreException while getting keys for compaction:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error while getting keys for compaction:${e.toString()}');
    }
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

  @override
  void setCompactionConfig(AtCompactionConfig atCompactionConfig) {
    this.atCompactionConfig = atCompactionConfig;
  }

  @override
  String toString() {
    return runtimeType.toString();
  }
}
