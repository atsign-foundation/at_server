import 'dart:collection';
import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';

export 'package:at_persistence_spec/at_persistence_spec.dart';

class AccessLogKeyStore implements LogKeyStore<int, AccessLogEntry> {
  var logger = AtSignLogger('AccessLogKeyStore');
  LazyBox _box;
  String storagePath;
  final _currentAtSign;

  AccessLogKeyStore(this._currentAtSign);

  void init(String storagePath) async {
    var boxName = 'access_log_' + AtUtils.getShaForAtSign(_currentAtSign);
    await Hive.init(storagePath);
    if (!Hive.isAdapterRegistered(AccessLogEntryAdapter().typeId)) {
      Hive.registerAdapter(AccessLogEntryAdapter());
    }
    _box = await Hive.openLazyBox(boxName);
    this.storagePath = storagePath;
  }

  @override
  Future add(AccessLogEntry accessLogEntry) async {
    var result;
    try {
      result = await _box.add(accessLogEntry);
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
  Future<AccessLogEntry> get(int key) async {
    try {
      var accessLogEntry = await _box.get(key);
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
      await _box.delete(key);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception deleting access log entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error deleting entry from access log:${e.toString()}');
    }
  }

  @override
  void delete(expiredKeys) {
    // TODO: implement delete
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    var totalKeys = 0;
    totalKeys = _box?.keys?.length;
    return totalKeys;
  }

  /// Returns the list of expired keys.
  /// @param expiryInDays - The count of days after which the keys expires
  /// @return List<dynamic> - The list of expired keys.
  @override
  Future<List> getExpired(int expiryInDays) async {
    var expiredKeys = <dynamic>[];
    var now = DateTime.now().toUtc();
    var accessLogMap = await _toMap();

    accessLogMap.forEach((key, value) {
      if (value.requestDateTime != null &&
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
      entries = _box.keys.toList().take(N).toList();
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
  int getSize() {
    var logSize = 0;
    var logLocation = Directory(storagePath);

    if (storagePath != null) {
      //The listSync function returns the list of files in the commit log storage location.
      // The below loop iterates recursively into sub-directories over each file and gets the file size using lengthSync function
      logLocation.listSync().forEach((element) {
        logSize = logSize + File(element.path).lengthSync();
      });
    }
    return logSize ~/ 1024;
  }

  @override
  Future update(int key, AccessLogEntry value) {
    // TODO: implement update
    return null;
  }

  ///The functions returns the top [length] visited atSign's.
  ///@param - length : The maximum number of atsign's to return
  ///@return Map : Returns a key value pair. Key is the atsign and value is the count of number of times the atsign is looked at.
  Future<Map> mostVisitedAtSigns(int length) async {
    var atSignMap = {};
    var accessLogMap = await _toMap();

    accessLogMap.forEach((key, value) {
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

    accessLogMap.forEach((key, value) {
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

  ///Closes the [accessLogKeyStore] instance.
  void close() async {
    await _box.close();
  }

  Future<Map> _toMap() async {
    var accessLogMap = {};
    var keys = _box.keys;
    var value;
    await Future.forEach(keys, (key) async {
      value = await _box.get(key);
      accessLogMap.putIfAbsent(key, () => value);
    });
    return accessLogMap;
  }
}
