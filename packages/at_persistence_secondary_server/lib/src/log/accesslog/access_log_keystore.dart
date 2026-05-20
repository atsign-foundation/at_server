import 'dart:collection';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';

export 'package:at_persistence_secondary_server/src/spec/spec.dart';

class AccessLogKeyStore
    with HiveBase<AccessLogEntry?>
    implements LogKeyStore<int, AccessLogEntry?> {
  final String _currentAtSign;
  late String _boxName;

  AccessLogKeyStore(this._currentAtSign);

  @override
  Future<void> initialize() async {
    _boxName = 'access_log_${AtUtils.getShaForAtSign(_currentAtSign)}';

    if (!Hive.isAdapterRegistered(AccessLogEntryAdapter().typeId)) {
      Hive.registerAdapter(AccessLogEntryAdapter());
    }
    await super.openBox(_boxName);
  }

  @override
  Future<int> add(AccessLogEntry? accessLogEntry) async {
    int result;
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
  Future<void> remove(int key) async {
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
  Future<void> removeAll(List<int> deleteKeysList) async {
    if (deleteKeysList.isEmpty) {
      return;
    }
    await _getBox().deleteAll(deleteKeysList);
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    int? totalKeys = 0;
    totalKeys = _getBox().keys.length;
    return totalKeys;
  }

  /// Returns the list of expired entry keys (Hive-assigned integer
  /// box keys), older than [expiryInDays] days.
  @override
  Future<Stream<int>> getExpired(int expiryInDays) async {
    var expiredKeys = <int>[];
    var now = DateTime.timestamp();
    var accessLogMap = await _toMap();
    accessLogMap.forEach((key, value) {
      if (value == null) {
        expiredKeys.add(key);
        return;
      }
      final requestDateTime = value.requestDateTime;
      if (requestDateTime != null &&
          requestDateTime
              .isBefore(now.subtract(Duration(days: expiryInDays)))) {
        expiredKeys.add(key);
      }
    });
    return Stream.fromIterable(expiredKeys);
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  List<int> getFirstNEntries(int N) {
    List<int> entries;
    try {
      entries = List<int>.from(_getBox().keys.toList().take(N).toList());
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
  Future<void> update(int key, AccessLogEntry? value) {
    throw UnimplementedError('AccessLogKeyStore.update is not supported');
  }

  /// Top [length] atSigns by `pol`-verb access-log entry count.
  /// Result map: atSign → visit count, ordered by descending count.
  Future<Map<String, int>> mostVisitedAtSigns(int length) async {
    final atSignMap = <String, int>{};
    final accessLogMap = await _toMap();
    accessLogMap.forEach((key, value) {
      if (value == null || value.verbName != 'pol') return;
      final from = value.fromAtSign;
      if (from == null) return;
      atSignMap[from] = (atSignMap[from] ?? 0) + 1;
    });
    final sortedKeys = atSignMap.keys.toList(growable: false)
      ..sort((k1, k2) => atSignMap[k2]!.compareTo(atSignMap[k1]!));
    if (sortedKeys.length < length) {
      length = sortedKeys.length;
    }
    return LinkedHashMap<String, int>.fromIterable(
        sortedKeys.toList().getRange(0, length),
        key: (k) => k as String,
        value: (k) => atSignMap[k as String]!);
  }

  /// Top [length] lookup keys by `lookup`-verb access-log entry
  /// count. Result map: lookup-key → visit count, ordered by
  /// descending count.
  Future<Map<String, int>> mostVisitedKeys(int length) async {
    final atKeys = <String, int>{};
    final accessLogMap = await _toMap();
    accessLogMap.forEach((key, value) {
      if (value != null &&
          value.verbName == 'lookup' &&
          value.lookupKey != null) {
        final lookup = value.lookupKey!;
        atKeys[lookup] = (atKeys[lookup] ?? 0) + 1;
      }
    });
    final sortedKeys = atKeys.keys.toList(growable: false)
      ..sort((k1, k2) => atKeys[k2]!.compareTo(atKeys[k1]!));
    if (sortedKeys.length < length) {
      length = sortedKeys.length;
    }
    return LinkedHashMap<String, int>.fromIterable(
        sortedKeys.toList().getRange(0, length),
        key: (k) => k as String,
        value: (k) => atKeys[k as String]!);
  }

  ///Get last [AccessLogEntry] entry.
  Future<AccessLogEntry> getLastEntry() async {
    final accessLogMap = await _toMap();
    return accessLogMap.values.last!;
  }

  ///Get last [AccessLogEntry] entry.
  Future<AccessLogEntry?> getLastPkamEntry() async {
    final accessLogMap = await _toMap();
    final items = accessLogMap.values
        .whereType<AccessLogEntry>()
        .where(
            (item) => item.verbName == 'pkam' && item.requestDateTime != null)
        .toList();
    items.sort((a, b) => a.requestDateTime!.compareTo(b.requestDateTime!));
    return (items.isNotEmpty) ? items.last : null;
  }

  Future<Map<int, AccessLogEntry?>> _toMap() async {
    final accessLogMap = <int, AccessLogEntry?>{};
    final keys = _getBox().keys;
    await Future.forEach(keys, (key) async {
      final value = await getValue(key);
      accessLogMap.putIfAbsent(key as int, () => value);
    });
    return accessLogMap;
  }

  BoxBase _getBox() {
    return super.getBox();
  }
}
