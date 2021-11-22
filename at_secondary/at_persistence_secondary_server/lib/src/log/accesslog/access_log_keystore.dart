import 'dart:collection';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';

export 'package:at_persistence_spec/at_persistence_spec.dart';

class AccessLogKeyStore
    with HiveBase<AccessLogEntry?>
    implements LogKeyStore<int, AccessLogEntry?> {
  var logger = AtSignLogger('AccessLogKeyStore');

  final _currentAtSign;
  late String _boxName;

  AccessLogKeyStore(this._currentAtSign);

  @override
  Future<void> initialize() async {
    _boxName = 'access_log_' + AtUtils.getShaForAtSign(_currentAtSign);

    if (!Hive.isAdapterRegistered(AccessLogEntryAdapter().typeId)) {
      Hive.registerAdapter(AccessLogEntryAdapter());
    }
    await super.openBox(_boxName);
  }

  @override
  Future add(AccessLogEntry? accessLogEntry) async {
    var result;
    try {
      result = await _getBox().add(accessLogEntry);
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
  Future<AccessLogEntry?> get(int key) async {
    try {
      var accessLogEntry = await getValue(key);
      return accessLogEntry;
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception get access log entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error getting entry from access log:${e.toString()}');
    }
  }

  @override
  Future remove(int key) async {
    try {
      await _getBox().delete(key);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception deleting access log entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error deleting entry from access log:${e.toString()}');
    }
  }

  @override
  void delete(expiredKeys) async {
    if (expiredKeys.isNotEmpty) {
      await _getBox().deleteAll(expiredKeys);
    }
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    int? totalKeys = 0;
    totalKeys = _getBox().keys.length;
    return totalKeys;
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
  List getFirstNEntries(int N) {
    var entries = [];
    try {
      entries = _getBox().keys.toList().take(N).toList();
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception getting first N entries:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to access log:${e.toString()}');
    }
    return entries;
  }

  @override
  Future update(int key, AccessLogEntry? value) {
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

    // box.toMap().forEach((key, value) {
    //   //Verify the records of pol verb in access log entry. To ignore the records of lookup(s)
    //   if (value.verbName == 'pol') {
    //     atSignMap.containsKey(value.fromAtSign)
    //         ? atSignMap[value.fromAtSign] = atSignMap[value.fromAtSign] + 1
    //         : atSignMap[value.fromAtSign] = 1;
    //   }
    // });
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
  Future<AccessLogEntry?> getLastEntry() async {
    var accessLogMap = await _toMap();
    return accessLogMap!.values.last;
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
    var value;
    await Future.forEach(keys, (key) async {
      value = await getValue(key);
      accessLogMap.putIfAbsent(key, () => value);
    });
    return accessLogMap;
  }

  BoxBase _getBox() {
    return super.getBox();
  }
}
