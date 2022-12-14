import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_log_keystore.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

/// Class to main access logs on the secondary server for from, cram, pol, lookup and plookup verbs
class AtAccessLog implements AtLogType<int, AccessLogEntry> {
  var logger = AtSignLogger('AtAccessLog');

  // ignore: prefer_typing_uninitialized_variables
  late AccessLogKeyStore _accessLogKeyStore;

  late AtCompactionConfig atCompactionConfig;

  AtAccessLog(AccessLogKeyStore keyStore) {
    _accessLogKeyStore = keyStore;
  }

  ///Creates a new entry with fromAtSign, verbName and optional parameter lookupKey for lookup and plookup verbs.
  ///@param fromAtSign : The another user atsign
  ///@param verbName : The verb performed by the atsign user
  ///@param lookupKey : The optional parameter to hold lookup key when performing lookup or plookup verb.
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
  Future<Map>? mostVisitedAtSigns(int length) async {
    return await _accessLogKeyStore.mostVisitedAtSigns(length);
  }

  ///The functions returns the top [length] visited atKey's.
  ///@param length : The recent number of keys to fetch
  ///@return Map : Returns a key value pair. Key is the atsign key looked up and
  ///value is number of times the key is looked up.
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
      await _accessLogKeyStore.deleteAll(keysList);
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

  Future<AccessLogEntry?> getLastAccessLogEntry() async {
    return await _accessLogKeyStore.getLastEntry();
  }

  Future<AccessLogEntry?> getLastPkamAccessLogEntry() async {
    return await _accessLogKeyStore.getLastPkamEntry();
  }

  ///Closes the [accessLogKeyStore] instance.
  void close() {
    _accessLogKeyStore.close();
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
