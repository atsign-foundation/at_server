// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_base.dart';
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

  /// Per-pass percentage of entries to drop when compaction is
  /// invoked. Captured from `AtSecondaryConfig` at factory time.
  final int compactionPercentage;
  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      preRemoveHooks = [];
  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      postRemoveHooks = [];

  /// Broadcast stream of mutations on this notification keystore.
  /// Emitted from `put`, `remove`, and `removeMany` after the
  /// underlying box write succeeds.
  final StreamController<KeyStoreChange> _changesController =
      StreamController<KeyStoreChange>.broadcast();

  /// In-memory expiry index: notification id → effective expiry
  /// instant (see [_effectiveExpiry]). Populated once in
  /// [initialize]; maintained on every mutation path — [put],
  /// [remove], [removeMany], [compact], [clear]. Backs
  /// [nextExpiresAt] / [peekExpired] / [getExpiredKeys] without a
  /// full-box deserialise.
  final Map<String, DateTime> _expiryIndex = {};

  /// The instant at which [n] is (or becomes) expired, folding all
  /// of [AtNotification.isExpired]'s branches into one comparable
  /// value: entries that are already expired by shape (status
  /// `expired`, null `expiresAt`, null `notificationDateTime`) are
  /// pinned to the epoch so every min/peek sees them immediately;
  /// otherwise the earlier of `expiresAt` and the
  /// `notificationDateTime + maxTtl` anti-bad-data cutoff.
  /// `n.isExpired()` is exactly `_effectiveExpiry(n) < now`.
  static DateTime _effectiveExpiry(AtNotification n) {
    if (n.notificationStatus == NotificationStatus.expired ||
        n.expiresAt == null ||
        n.notificationDateTime == null) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    final maxTtlCutoff = n.notificationDateTime!.add(AtNotification.maxTtl);
    return n.expiresAt!.isBefore(maxTtlCutoff) ? n.expiresAt! : maxTtlCutoff;
  }

  @override
  Stream<KeyStoreChange> get changes => _changesController.stream;

  @override
  bool get supportsSnapshots => false;

  @override
  Future<KeyStoreSnapshot<String, AtNotification, dynamic>> snapshot() async {
    return _HiveBestEffortNotifSnapshot(this);
  }

  @override
  Future<KeyStoreStats> stats() async {
    final box = _getBox();
    final total = box.length;
    int ttl = 0;
    DateTime? oldest;
    DateTime? newest;
    for (final key in box.keys) {
      final entry = await getValue(key);
      if (entry == null) continue;
      if (entry.ttl != null) ttl++;
      final c = entry.notificationDateTime;
      if (c != null) {
        if (oldest == null || c.isBefore(oldest)) oldest = c;
        if (newest == null || c.isAfter(newest)) newest = c;
      }
    }
    return KeyStoreStats(
      totalKeys: total,
      ttlKeys: ttl,
      // Notifications have no `ttb` concept (they're queued
      // outbound — there's no "available at" semantics).
      ttbKeys: 0,
      sizeBytes: 0,
      oldestCreatedAt: oldest,
      newestCreatedAt: newest,
    );
  }

  @override
  Future<R> transaction<R>(
    Future<R> Function(KeyStoreTxn<String, AtNotification, dynamic> txn) body,
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
    await _populateExpiryIndex();
  }

  /// One-time full scan that seeds [_expiryIndex] from the box.
  /// Same cost pattern as the main keystore's expiry-cache init.
  Future<void> _populateExpiryIndex() async {
    _expiryIndex.clear();
    for (final key in _getBox().keys) {
      final entry = await getValue(key);
      if (entry == null) continue;
      _expiryIndex[key] = _effectiveExpiry(entry);
    }
  }

  /// You **must** subsequently call [init]
  HiveAtNotificationKeystore(this.currentAtSign,
      {this.compactionPercentage = 30}) {
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
  Future<int?> put(key, value, {bool skipCommit = false}) async {
    if (key.length > maxKeyLengthWithoutCached) {
      throw DataStoreException(
          'key length ${key.length} is greater than $maxKeyLengthWithoutCached chars');
    }
    final wasPresent = await exists(key);
    await _getBox().put(key, value);
    _expiryIndex[key] = _effectiveExpiry(value);
    _changesController.add(wasPresent ? KeyUpdated(key) : KeyAdded(key));
    return null;
  }

  @override
  Future<int?> create(key, value, {bool skipCommit = false}) async {
    // Notification keystore doesn't distinguish create-vs-update;
    // delegate to put() which atomically sets the entry regardless.
    return put(key, value, skipCommit: skipCommit);
  }

  @override
  Future<bool> deleteExpiredKeys() async {
    var result = true;
    try {
      var expiredKeys = await (await getExpiredKeys()).toList();
      if (expiredKeys.isNotEmpty) {
        await Future.forEach(expiredKeys, (expiredKey) async {
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
  Future<Stream<String>> getExpiredKeys() async {
    // Answered from _expiryIndex — _effectiveExpiry(n) < now is
    // exactly n.isExpired(), without deserialising every entry.
    final now = DateTime.timestamp();
    final expiredKeys = <String>[];
    _expiryIndex.forEach((key, expiry) {
      if (expiry.isBefore(now)) {
        expiredKeys.add(Utf7.encode(key));
      }
    });
    return Stream.fromIterable(expiredKeys);
  }

  @override
  Future<DateTime?> nextExpiresAt() async {
    DateTime? min;
    for (final expiry in _expiryIndex.values) {
      if (min == null || expiry.isBefore(min)) min = expiry;
    }
    return min;
  }

  @override
  Future<Stream<String>> peekExpired({DateTime? asOf, int? limit}) async {
    final cutoff = asOf ?? DateTime.timestamp();
    if (limit != null && limit <= 0) return const Stream.empty();
    final hits = <MapEntry<String, DateTime>>[];
    _expiryIndex.forEach((key, expiry) {
      if (!expiry.isAfter(cutoff)) hits.add(MapEntry(key, expiry));
    });
    hits.sort((a, b) => a.value.compareTo(b.value));
    final limited = limit == null ? hits : hits.take(limit);
    return Stream.fromIterable(limited.map((e) => Utf7.encode(e.key)));
  }

  @override
  Future<Stream<String>> getKeys({String? regex}) async {
    var keys = <String>[];
    // ignore: prefer_typing_uninitialized_variables
    var encodedKeys;

    if (_getBox().keys.isEmpty) {
      return const Stream.empty();
    }
    // If regular expression is not null or not empty, filter keys on regular expression.
    if (regex != null && regex.isNotEmpty) {
      encodedKeys = _getBox().keys.where(
          (element) => Utf7.decode(element).toString().contains(RegExp(regex)));
    } else {
      encodedKeys = _getBox().keys.toList();
    }
    encodedKeys?.forEach((key) => keys.add(Utf7.decode(key)));
    return Stream.fromIterable(keys);
  }

  @override
  Future<int?> remove(key, {bool skipCommit = false}) async {
    for (final hook in preRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }
    final wasPresent = await exists(key);
    await _getBox().delete(key);
    _expiryIndex.remove(key);

    for (final hook in postRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }
    if (wasPresent) {
      _changesController.add(KeyRemoved(key));
    }
    return null;
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
  Future<bool> exists(String key) async {
    return _getBox().keys.contains(key);
  }

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
    for (final k in present) {
      _expiryIndex.remove(k);
    }
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
  Future<Map<String, AtNotification>> getMany(List<String> keys) async {
    final result = <String, AtNotification>{};
    for (final k in keys) {
      if (!_getBox().keys.contains(k)) continue;
      final value = await getValue(k);
      if (value != null) result[k] = value;
    }
    return result;
  }

  @override
  int entriesCount() {
    return _getBox().keys.length;
  }

  /// Compact the notification queue. Drops every expired
  /// notification — those are the only entries that ever leave the
  /// queue this way.
  @override
  Stream<String> compact(bool dryRun) async* {
    final List<String> expired = await (await getExpiredKeys()).toList();
    if (dryRun) {
      for (final key in expired) {
        yield key;
      }
      return;
    }
    await _getBox().deleteAll(expired);
    for (final key in expired) {
      _expiryIndex.remove(key);
      yield key;
    }
  }

  @override
  String toString() {
    return runtimeType.toString();
  }

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

  /// Drop every entry from the underlying box AND the in-memory
  /// expiry index, without closing the box. Used by
  /// [AtPersistenceBundle.clear] for cheap test isolation.
  Future<void> clear() async {
    await _getBox().clear();
    _expiryIndex.clear();
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

class _HiveAtNotificationKeystoreTxn
    implements KeyStoreTxn<String, AtNotification, dynamic> {
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
  Future<AtNotification?> get(key) async {
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
    return _store.exists(key);
  }
}

class _HiveBestEffortNotifSnapshot
    implements KeyStoreSnapshot<String, AtNotification, dynamic> {
  final HiveAtNotificationKeystore _store;
  bool _released = false;

  _HiveBestEffortNotifSnapshot(this._store);

  @override
  Future<AtNotification?> get(key) async {
    if (_released) throw StateError('Snapshot has been released');
    return await _store.get(key);
  }

  @override
  Future<void> release() async {
    _released = true;
  }
}
