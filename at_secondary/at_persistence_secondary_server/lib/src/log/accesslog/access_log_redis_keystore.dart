import 'dart:collection';
import 'dart:convert';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:dartis/dartis.dart';
import 'package:redis/redis.dart';

class AccessLogRedisKeyStore implements LogKeyStore<int, AccessLogEntry> {
  final logger = AtSignLogger('AccessLogRedisKeyStore');
  var redis_connection;
  var redis_commands;
  final String ACCESS_LOG = 'at_access_log';
  String storagePath;
  final _currentAtSign;

  AccessLogRedisKeyStore(this._currentAtSign);


  Future<void> init(String storagePath) async {
    var success = false;
    try {
      // Connects.
      //TODO - need to create connection pool
      redis_connection = RedisConnection();
      redis_commands = await redis_connection.connect('localhost', 6379);
      // Runs some commands.
      await redis_commands.send_object(['AUTH', 'mypassword']);
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
      result = await redis_commands.send_object(['RPUSH', ACCESS_LOG, value]);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to access log:${e.toString()}');
    }
    return result;
  }

  @override
  void delete(expiredKeys) {
    // TODO: implement delete
  }

  @override
  Future<int> entriesCount() async {
    var totalKeys = 0;
    totalKeys = await redis_commands.send_object(['LLEN', ACCESS_LOG]);
    return totalKeys;
  }

  @override
  Future<AccessLogEntry> get(int key) async {
    try {
      var accessLogEntry;
      var value =
          await redis_commands.send_object(['LRANGE', ACCESS_LOG, key, key]);
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

  @override
  Future<List> getExpired(int expiryInDays) async {
    var expiredKeys = <dynamic>[];
    var now = DateTime.now().toUtc();
    var values =
        await redis_commands.send_object(['LRANGE', ACCESS_LOG, 0, -1]);
    for (var entry in values) {
      var value = AccessLogEntry.fromJson(json.decode(entry));
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
      entries =
          await redis_commands.send_object(['LRANGE', ACCESS_LOG, 0, N - 1]);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception getting first N entries:${e.toString()}');
    }
    return entries;
  }

  @override
  int getSize() {
    // TODO
    var logSize = 0;
    return logSize;
  }

  @override
  Future remove(int key) async {
    try {
      await redis_commands.send_object(['LREM', ACCESS_LOG, key]);
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
    var values =
        await redis_commands.send_object(['LRANGE', ACCESS_LOG, 0, -1]);
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
    var values =
        await redis_commands.send_object(['LRANGE', ACCESS_LOG, 0, -1]);
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
