// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';

/// Hive-backed implementation of [AtNotificationKeystore]: a
/// queue of pending atSign-to-atSign notifications, persisted
/// server-side.
class HiveAtNotificationKeystore
    with HiveBase<AtNotification?>
    implements AtNotificationKeystore {
  late String currentAtSign;
  late String _boxName;
  static const int maxKeyLengthWithoutCached = 248;
  late AtCompactionConfig atCompactionConfig;
  @override
  List<Future Function(String key, {required bool skipCommit})> preRemoveHooks =
      [];
  @override
  List<Future Function(String key, {required bool skipCommit})>
      postRemoveHooks = [];

  /// Broadcast stream of mutations on this notification keystore.
  /// Emitted from `put`, `remove`, and `removeMany` after the
  /// underlying box write succeeds.
  final StreamController<KeyStoreChange> _changesController =
      StreamController<KeyStoreChange>.broadcast();

  @override
  Stream<KeyStoreChange> get changes => _changesController.stream;

  @override
  bool get supportsPathQueries => false;

  @override
  bool get supportsSnapshots => false;

  @override
  Future<KeyStoreSnapshot> snapshot() async {
    return _HiveBestEffortNotifSnapshot(this);
  }

  @override
  Stream<KeyEntry> queryByPath({
    required KeyPattern keyPattern,
    required Predicate predicate,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  }) {
    throw UnsupportedError(
      'HiveAtNotificationKeystore does not support push-down path queries. '
      'Check `supportsPathQueries` before calling.',
    );
  }

  @override
  Future<R> transaction<R>(
    Future<R> Function(KeyStoreTxn txn) body,
  ) async {
    final txn = _HiveAtNotificationKeystoreTxn(this);
    final R result;
    try {
      result = await body(txn);
    } catch (_) {
      rethrow;
    }
    for (final op in txn._ops.values) {
      await op.apply(this);
    }
    return result;
  }

  static final HiveAtNotificationKeystore _singleton =
      HiveAtNotificationKeystore('@fake_atsign_fake_fake_fake');

  @Deprecated("Obsolete; use standard constructor")
  factory HiveAtNotificationKeystore.getInstance() {
    return _singleton;
  }

  final _logger = AtSignLogger('HiveAtNotificationKeystore');

  static bool _typesRegistered = false;

  @override
  Future<void> initialize() async {
    _boxName = 'notifications_${AtUtils.getShaForAtSign(currentAtSign)}';
    await super.openBox(_boxName);
  }

  /// You **must** subsequently call [init]
  HiveAtNotificationKeystore(this.currentAtSign) {
    if (!_typesRegistered) {
      Hive.registerAdapter(AtNotificationAdapter());
      Hive.registerAdapter(OperationTypeAdapter());
      Hive.registerAdapter(NotificationTypeAdapter());
      Hive.registerAdapter(NotificationStatusAdapter());
      Hive.registerAdapter(NotificationPriorityAdapter());
      Hive.registerAdapter(MessageTypeAdapter());
      if (!Hive.isAdapterRegistered(AtMetaDataAdapter().typeId)) {
        Hive.registerAdapter(AtMetaDataAdapter());
      }
      if (!Hive.isAdapterRegistered(PublicKeyHashAdapter().typeId)) {
        Hive.registerAdapter(PublicKeyHashAdapter());
      }
      _typesRegistered = true;
    }
  }

  bool isEmpty() {
    return _getBox().isEmpty;
  }

  /// Returns a list of atNotification sorted on notification date time.
  @Deprecated('highly inefficient')
  Future<List> getValues() async {
    var returnList = [];
    var notificationLogMap = await _toMap();
    returnList = notificationLogMap!.values.toList();
    returnList.sort(
        (k1, k2) => k1.notificationDateTime.compareTo(k2.notificationDateTime));
    return returnList;
  }

  @override
  Future<AtNotification?> get(key) async {
    return await getValue(key);
  }

  @override
  Future<dynamic> put(key, value, {bool skipCommit = false}) async {
    if (key.length > maxKeyLengthWithoutCached) {
      throw DataStoreException(
          'key length ${key.length} is greater than $maxKeyLengthWithoutCached chars');
    }
    final wasPresent = isKeyExists(key);
    await _getBox().put(key, value);
    _changesController
        .add(wasPresent ? KeyUpdated(key as String) : KeyAdded(key as String));
  }

  @override
  Future<dynamic> create(key, value, {bool skipCommit = false}) async {
    throw UnimplementedError();
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    var result = true;
    try {
      var expiredKeys = await getExpiredKeys();
      if (expiredKeys.isNotEmpty) {
        await Future.forEach(expiredKeys, (expiredKey) async {
          // Delete entries for expired keys will not be added to commitLog
          await remove(expiredKey, skipCommit: true);
        });
      } else {
        _logger.finest('notification key store. No expired notifications');
      }
    } on Exception catch (e) {
      result = false;
      _logger.severe('Exception in deleteExpired keys: ${e.toString()}');
      throw DataStoreException(
          'exception in deleteExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      _logger.severe('Error occurred in notification keystore: $error');
      throw DataStoreException(error.message);
    }
    return result;
  }

  @override
  Future<List<String>> getExpiredKeys() async {
    List<String> expiredKeys = <String>[];
    try {
      for (final key in _getBox().keys) {
        var value = await get(key);
        if (value != null && value.isExpired()) {
          expiredKeys.add(Utf7.encode(key));
        }
      }
    } on Exception catch (e) {
      _logger.severe('exception in hive get expired keys:${e.toString()}');
      throw DataStoreException('exception in getExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      _logger.severe('HiveSecondaryKeyStore get error: $error');
      throw DataStoreException(error.message);
    }
    return expiredKeys;
  }

  @override
  List getKeys({String? regex}) {
    var keys = <String>[];
    // ignore: prefer_typing_uninitialized_variables
    var encodedKeys;

    if (_getBox().keys.isEmpty) {
      return [];
    }
    // If regular expression is not null or not empty, filter keys on regular expression.
    if (regex != null && regex.isNotEmpty) {
      encodedKeys = _getBox().keys.where(
          (element) => Utf7.decode(element).toString().contains(RegExp(regex)));
    } else {
      encodedKeys = _getBox().keys.toList();
    }
    encodedKeys?.forEach((key) => keys.add(Utf7.decode(key)));
    return encodedKeys;
  }

  @override
  Future remove(key, {bool skipCommit = false}) async {
    for (final hook in preRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }
    assert(key != null);
    final wasPresent = isKeyExists(key);
    await _getBox().delete(key);

    for (final hook in postRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }
    if (wasPresent) {
      _changesController.add(KeyRemoved(key as String));
    }
  }

  Future<Map>? _toMap() async {
    var notificationLogMap = {};
    var keys = _getBox().keys;
    AtNotification? value;
    await Future.forEach(keys, (key) async {
      value = await getValue(key);
      notificationLogMap.putIfAbsent(key, () => value);
    });
    return notificationLogMap;
  }

  BoxBase _getBox() {
    return super.getBox();
  }

  @override
  bool isKeyExists(String key) {
    return _getBox().keys.contains(key);
  }

  @override
  Future<bool> exists(String key) async => isKeyExists(key);

  @override
  Future<int> removeMany(List keys, {bool skipCommit = false}) async {
    if (keys.isEmpty) return 0;
    final box = _getBox();
    final present = <dynamic>{};
    for (final k in keys) {
      if (present.contains(k)) continue;
      if (box.keys.contains(k)) present.add(k);
    }
    if (present.isEmpty) return 0;
    // preRemoveHooks per present key.
    for (final k in present) {
      for (final hook in preRemoveHooks) {
        await hook(k, skipCommit: skipCommit);
      }
    }
    await box.deleteAll(present);
    // postRemoveHooks per present key.
    for (final k in present) {
      for (final hook in postRemoveHooks) {
        await hook(k, skipCommit: skipCommit);
      }
    }
    // Emit a KeyRemoved event per actually-removed key.
    for (final k in present) {
      _changesController.add(KeyRemoved(k as String));
    }
    return present.length;
  }

  @override
  Future<Map<dynamic, dynamic>> getMany(List keys) async {
    final result = <dynamic, dynamic>{};
    for (final k in keys) {
      if (!_getBox().keys.contains(k)) continue;
      result[k] = await getValue(k);
    }
    return result;
  }

  @override
  Stream<String> scanKeys(
    KeyPattern pattern, {
    bool includeExpired = false,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  }) async* {
    // Notification keys are random ids, not atKey-shaped, so the
    // structured fields on KeyPattern (sharedBy / sharedWith /
    // namespace / idPrefix) don't apply here. We honour
    // `isUnrestricted` (yields every notification id) and `idPrefix`
    // (treated as a leading-substring match on the id), but
    // sharedBy / sharedWith / namespace cannot match — return empty
    // when those are set.
    if (pattern.sharedBy != null ||
        pattern.sharedWith != null ||
        pattern.namespace != null) {
      return;
    }

    // Collect matching ids (and the entry, if we need it for sorting).
    final matched = <String>[];
    final entries = <String, AtNotification>{};
    for (final key in _getBox().keys) {
      final id = key as String;
      AtNotification? entry;
      if (!includeExpired || orderBy != null) {
        entry = await getValue(id);
        if (!includeExpired && entry != null && entry.isExpired()) continue;
      }
      if (pattern.idPrefix != null && !id.startsWith(pattern.idPrefix!)) {
        continue;
      }
      matched.add(id);
      if (entry != null) entries[id] = entry;
    }

    // Order.
    switch (orderBy) {
      case null:
        // Backend's natural order — keys.iterator order from the box.
        break;
      case OrderByKey.byKey:
        matched.sort();
        break;
      case OrderByKey.byCreatedAt:
        matched.sort((a, b) =>
            _compareNullableDate(
              entries[a]?.notificationDateTime,
              entries[b]?.notificationDateTime,
            ));
        break;
      case OrderByKey.byExpiresAt:
        matched.sort((a, b) =>
            _compareNullableDate(entries[a]?.expiresAt, entries[b]?.expiresAt));
        break;
    }

    // Skip + limit.
    final skipN = skip ?? 0;
    int yielded = 0;
    for (int i = skipN; i < matched.length; i++) {
      if (limit != null && yielded >= limit) break;
      yield matched[i];
      yielded++;
    }
  }

  /// Sort comparator that puts `null` values last.
  int _compareNullableDate(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  @override
  int entriesCount() {
    return _getBox().keys.length;
  }

  @override
  Future getMeta(key) {
    throw UnimplementedError();
  }

  @override
  Future putAll(key, value, metadata) {
    throw UnimplementedError();
  }

  @override
  Future putMeta(key, metadata) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteKeyForCompaction(List<String> keysList) async {
    await _getBox().deleteAll(keysList);
  }

  @override
  Future<List<String>> getKeysToDeleteOnCompaction() async {
    return await getExpiredKeys();
  }

  @override
  void setCompactionConfig(AtCompactionConfig atCompactionConfig) {
    this.atCompactionConfig = atCompactionConfig;
  }

  @override
  String toString() {
    return runtimeType.toString();
  }

  @override
  AtLogType? commitLog;

  @override
  Stream<AtNotification> iterate() async* {
    // The notification keystore is backed by a LazyBox, so we can't
    // synchronously `box.get(key)` — use the Hive base's `getValue`,
    // which awaits the lazy fetch.
    for (final key in _getBox().keys) {
      final entry = await getValue(key);
      if (entry != null) yield entry;
    }
  }

  /// Drop every entry from the underlying box without closing it.
  /// Used by [AtPersistenceBundle.clear] for cheap test isolation.
  Future<void> clear() async {
    await _getBox().clear();
  }
}

abstract class _NotifBufferedOp {
  Future<void> apply(HiveAtNotificationKeystore store);
}

class _NotifBufferedPut implements _NotifBufferedOp {
  final dynamic key;
  final dynamic value;
  _NotifBufferedPut(this.key, this.value);

  @override
  Future<void> apply(HiveAtNotificationKeystore store) async {
    await store.put(key, value);
  }
}

class _NotifBufferedRemove implements _NotifBufferedOp {
  final dynamic key;
  _NotifBufferedRemove(this.key);

  @override
  Future<void> apply(HiveAtNotificationKeystore store) async {
    await store.remove(key);
  }
}

class _HiveAtNotificationKeystoreTxn implements KeyStoreTxn {
  final HiveAtNotificationKeystore _store;
  final Map<dynamic, _NotifBufferedOp> _ops = <dynamic, _NotifBufferedOp>{};

  _HiveAtNotificationKeystoreTxn(this._store);

  @override
  Future<void> put(key, value, metadata) async {
    _ops[key] = _NotifBufferedPut(key, value);
  }

  @override
  Future<void> remove(key) async {
    _ops[key] = _NotifBufferedRemove(key);
  }

  @override
  Future<dynamic> get(key) async {
    final buffered = _ops[key];
    if (buffered is _NotifBufferedPut) return buffered.value;
    if (buffered is _NotifBufferedRemove) return null;
    return await _store.get(key);
  }

  @override
  Future<bool> exists(key) async {
    final buffered = _ops[key];
    if (buffered is _NotifBufferedPut) return true;
    if (buffered is _NotifBufferedRemove) return false;
    return _store.isKeyExists(key);
  }
}

class _HiveBestEffortNotifSnapshot implements KeyStoreSnapshot {
  final HiveAtNotificationKeystore _store;
  bool _released = false;

  _HiveBestEffortNotifSnapshot(this._store);

  @override
  Future<dynamic> get(key) async {
    if (_released) throw StateError('Snapshot has been released');
    return await _store.get(key);
  }

  @override
  Stream scanKeys(KeyPattern pattern) {
    if (_released) throw StateError('Snapshot has been released');
    return _store.scanKeys(pattern);
  }

  @override
  Future<void> release() async {
    _released = true;
  }
}
