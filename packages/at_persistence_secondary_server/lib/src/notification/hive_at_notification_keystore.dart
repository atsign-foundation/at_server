// ignore_for_file: non_constant_identifier_names

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
    await _getBox().put(key, value);
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
    await _getBox().delete(key);

    for (final hook in postRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
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
    for (final key in _getBox().keys) {
      final id = key as String;
      if (!includeExpired) {
        final entry = await getValue(id);
        if (entry != null && entry.isExpired()) continue;
      }
      if (pattern.idPrefix != null && !id.startsWith(pattern.idPrefix!)) {
        continue;
      }
      yield id;
    }
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
