import 'dart:collection';
import 'dart:convert';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:dartis/dartis.dart' as redis;

/// Class contains implementation for redis keystore.
class AccessLogRedisKeyStore implements LogKeyStore<int, AccessLogEntry> {
  final logger = AtSignLogger('AccessLogRedisKeyStore');
  var redis_client;
  var redis_commands;
  final String ACCESS_LOG = 'at_access_log';
  String storagePath;

  AccessLogRedisKeyStore();

  Future<void> init(String url, {String password}) async {
    var success = false;
    try {
      // Connects.
      redis_client = await redis.Client.connect(url);
      // Runs some commands.
      redis_commands = redis_client.asCommands<String, String>();
      await redis_commands.auth(password);
    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: ' + e.toString());
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    }
    return success;
  }

  @override
  Future add(AccessLogEntry accessLogEntry) async {
    var result;
    try {
      var value = (accessLogEntry != null)
          ? json.encode(accessLogEntry.toJson())
          : null;
      result = await redis_commands.rpush(ACCESS_LOG, value: value);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to access log:${e.toString()}');
    }
    return result;
  }

  @override
  Future<int> entriesCount() async {
    var totalKeys = 0;
    totalKeys = await redis_commands.llen(ACCESS_LOG);
    return totalKeys;
  }

  /// Returns the [AccessLogEntry] for the key.
  @override
  Future<AccessLogEntry> get(int key) async {
    try {
      var accessLogEntry;
      var value = await redis_commands.lrange(ACCESS_LOG, key, key);
      if (value == null) {
        return accessLogEntry;
      }
      var value_json = (value != null) ? json.decode(value) : null;
      accessLogEntry = AccessLogEntry.fromJson(value_json);
      return accessLogEntry;
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception get access log entry:${e.toString()}');
    }
  }

  /// Returns the expired keys
  @override
  Future<List<dynamic>> getExpired(int expiryInDays) async {
    var expiredKeys = <dynamic>[];
    var now = DateTime.now().toUtc();
    var values = await redis_commands.lrange(ACCESS_LOG, 0, -1);
    ///Iterates on the access log entries
    for (var entry in values) {
      var value = AccessLogEntry.fromJson(json.decode(entry));
      /// If the date-time of entry in access log is before the number of days to expire,
      /// index of the value is added to expiredKeys List.
      if (value.requestDateTime != null &&
          value.requestDateTime
              .isBefore(now.subtract(Duration(days: expiryInDays)))) {
        expiredKeys.add(values.indexOf(entry));
      }
    }
    return expiredKeys;
  }

  @override
  Future<List> getFirstNEntries(int N) async {
    var entries = [];
    try {
      var result = await redis_commands.lrange(ACCESS_LOG, 0, N - 1);
      /// Iterates of access log entries and adds the index of each entry to list.
      result.forEach((entry) {
        entries.add(result.indexOf(entry));
      });
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception getting first N entries:${e.toString()}');
    }
    return entries;
  }

  @override
  Future<int> getSize() async {
    //Returning number of entries
    var logSize = await redis_commands.llen(ACCESS_LOG);
    return logSize;
  }

  /// Removed the entry from the access log.
  @override
  Future<void> remove(int key) async {
    try {
      var value = await redis_commands.lrange(ACCESS_LOG, key, key);
      /// Removes the value from the access log.
      if (value != null && value.isNotEmpty) {
        await redis_commands.lrem(ACCESS_LOG, 1, value[0]);
      }
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception deleting access log entry:${e.toString()}');
    }
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
    var values = await redis_commands.lrange(ACCESS_LOG, 0, -1);
    for (var entry in values) {
      var value = AccessLogEntry.fromJson(json.decode(entry));
      //Verify the records of pol verb in access log entry. To ignore the records of lookup(s)
      if (value.verbName == 'pol') {
        atSignMap.containsKey(value.fromAtSign)
            ? atSignMap[value.fromAtSign] = atSignMap[value.fromAtSign] + 1
            : atSignMap[value.fromAtSign] = 1;
      }
    }
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
    var values = await redis_commands.lrange(ACCESS_LOG, 0, -1);
    for (var entry in values) {
      var value = AccessLogEntry.fromJson(json.decode(entry));
      //Verify the record in access entry is of from verb. To ignore the records of lookup(s)
      if (value.verbName == 'lookup' && value.lookupKey != null) {
        atKeys.containsKey(value.lookupKey)
            ? atKeys[value.lookupKey] = atKeys[value.lookupKey] + 1
            : atKeys[value.lookupKey] = 1;
      }
    }
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
}
