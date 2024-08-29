import 'dart:collection';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';
export 'package:at_persistence_spec/at_persistence_spec.dart';

class AccessLogKeyStore
    with HiveBase<AccessLogEntry?>
    implements LogKeyStore<String, AccessLogEntry?> {
  final String _currentAtSign;
  late String _boxName;
  int internalKey = -1;

  AccessLogKeyStore(this._currentAtSign);

  @override
  void initialize() {
    _boxName = 'access_log_${AtUtils.getShaForAtSign(_currentAtSign)}';
    Hive.registerAdapter('AccessLogEntry', AccessLogEntry.fromJson);
    super.openBox(_boxName);
    if (getBox().keys.isNotEmpty) {
      var lastKey = getBox().keys.last;
      var lastAccessEntry = getBox().get(lastKey);
      if (lastAccessEntry != null) {
        internalKey = lastAccessEntry.key!;
      }
    }
  }

  @override
  void add(AccessLogEntry? accessLogEntry) {
    try {
      internalKey++;
      accessLogEntry!.key = internalKey;
      _getBox().put(internalKey.toString(), accessLogEntry);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to access log:${e.toString()}');
    }
  }

  @override
  Future<AccessLogEntry?> get(String key) async {
    try {
      var accessLogEntry = getValue(key);
      return accessLogEntry;
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception get access log entry:${e.toString()}');
    }
  }

  @override
  void remove(String key) {
    try {
      _getBox().delete(key);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception deleting access log entry:${e.toString()}');
    }
  }

  @override
  void removeAll(List<String> deleteKeysList) {
    if (deleteKeysList.isEmpty) {
      return;
    }
    _getBox().deleteAll(deleteKeysList);
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    return _getBox().length;
  }

  /// Returns the list of expired keys.
  /// @param expiryInDays - The count of days after which the keys expires
  /// @return List<dynamic> - The list of expired keys.
  @override
  Future<List<dynamic>> getExpired(int expiryInDays) async {
    var expiredKeys = <dynamic>[];
    var now = DateTime.now().toUtc();
    var accessLogMap = await _toMap();
    accessLogMap!.forEach((key, value) {
      if (value == null) {
        expiredKeys.add(key);
      } else if (value.requestDateTime != null &&
          value.requestDateTime
              .isBefore(now.subtract(Duration(days: expiryInDays)))) {
        expiredKeys.add(key);
      }
    });
    return expiredKeys;
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  List<String> getFirstNEntries(int N) {
    List<String> entries;
    try {
      entries = List<String>.from(_getBox().keys.toList().take(N).toList());
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception getting first N entries:${e.toString()}');
    }
    return entries;
  }

  @override
  void update(String key, AccessLogEntry? value) {
    // TODO: implement update
    throw 'Not implemented';
  }

  ///The functions returns the top [length] visited atSign's.
  ///@param - length : The maximum number of atsign's to return
  ///@return Map : Returns a key value pair. Key is the atsign and value is the count of number of times the atsign is looked at.
  Future<Map> mostVisitedAtSigns(int length) async {
    var atSignMap = {};
    var accessLogMap = await _toMap();
    accessLogMap!.forEach((key, value) {
      //Verify the records of pol verb in access log entry. To ignore the records of lookup(s)
      if (value.verbName == 'pol') {
        atSignMap.containsKey(value.fromAtSign)
            ? atSignMap[value.fromAtSign] = atSignMap[value.fromAtSign] + 1
            : atSignMap[value.fromAtSign] = 1;
      }
    });

    // Iterate over the atKeys map and sort the keys on value
    var sortedKeys = atSignMap.keys.toList(growable: false)
      ..sort((k1, k2) => atSignMap[k2].compareTo(atSignMap[k1]));
    // If the length of the sortedKeys is less the length [var length] set length to sortedKeys length
    if (sortedKeys.length < length) {
      length = sortedKeys.length;
    }
    var sortedMap = LinkedHashMap.fromIterable(
        sortedKeys.toList().getRange(0, length),
        key: (k) => k,
        value: (k) => atSignMap[k]);

    return sortedMap;
  }

  ///The functions returns the top [length] visited atKey's.
  ///@param length : The recent number of keys to fetch
  ///@return Map : Returns a key value pair. Key is the atsign key looked up and
  ///value is number of times the key is looked up.
  Future<Map> mostVisitedKeys(int length) async {
    var atKeys = {};
    var accessLogMap = await _toMap();
    accessLogMap!.forEach((key, value) {
      //Verify the record in access entry is of from verb. To ignore the records of lookup(s)
      if (value.verbName == 'lookup' && value.lookupKey != null) {
        atKeys.containsKey(value.lookupKey)
            ? atKeys[value.lookupKey] = atKeys[value.lookupKey] + 1
            : atKeys[value.lookupKey] = 1;
      }
    });
    // Iterate over the atKeys map and sort the keys on value
    var sortedKeys = atKeys.keys.toList(growable: false)
      ..sort((k1, k2) => atKeys[k2].compareTo(atKeys[k1]));
    // If the length of the sortedKeys is less the length [var length] set length to sortedKeys length
    if (sortedKeys.length < length) {
      length = sortedKeys.length;
    }
    var sortedMap = LinkedHashMap.fromIterable(
        sortedKeys.toList().getRange(0, length),
        key: (k) => k,
        value: (k) => atKeys[k]);

    return sortedMap;
  }

  ///Get last [AccessLogEntry] entry.
  Future<AccessLogEntry> getLastEntry() async {
    final box = getBox();
    return box.get(box.keys.last);
  }

  ///Get last [AccessLogEntry] entry.
  Future<AccessLogEntry?> getLastPkamEntry() async {
    var accessLogMap = await _toMap();
    var items = accessLogMap!.values.toList();
    items.removeWhere((item) => (item.verbName != 'pkam'));
    items.sort((a, b) => a.requestDateTime.compareTo(b.requestDateTime));
    return (items.isNotEmpty) ? items.last : null;
  }

  Future<Map>? _toMap() async {
    var accessLogMap = {};
    var keys = _getBox().keys;
    AccessLogEntry? value;
    for (var key in keys) {
      value = getValue(key);
      accessLogMap.putIfAbsent(key, () => value);
    }
    return accessLogMap;
  }

  Box _getBox() {
    return super.getBox();
  }
}
