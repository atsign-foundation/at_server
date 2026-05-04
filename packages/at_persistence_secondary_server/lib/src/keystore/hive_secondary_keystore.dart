// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

class HiveSecondaryKeyStore
    implements SecondaryKeyStore<String, AtData?, AtMetaData?> {
  final AtSignLogger logger = AtSignLogger('HiveSecondaryKeyStore');
  final String expiresAt = 'expiresAt';
  final String availableAt = 'availableAt';
  static const int maxKeyLength = 255;
  static const int maxKeyLengthWithoutCached = 248;

  HivePersistenceManager? persistenceManager;
  late HiveAtCommitLog _commitLog;
  @override
  List<Future Function(String key, {required bool skipCommit})> preRemoveHooks =
      [];
  @override
  List<Future Function(String key, {required bool skipCommit})>
      postRemoveHooks = [];

  /// A map-based cache that stores "expiresAt" and "availableAt" from AtMetadata
  /// of keys with TTL or TTB set, to efficiently track the active or expired state
  /// of each key based on their respective TTB or TTL values.
  final HashMap<String, Map<String, DateTime?>> _expiryKeysCache = HashMap();

  /// Broadcast stream of mutations on this keystore. Emitted from
  /// `create`, `put` (update branch), `remove`, and `removeMany`
  /// after the underlying box write succeeds.
  final StreamController<KeyStoreChange> _changesController =
      StreamController<KeyStoreChange>.broadcast();

  @override
  Stream<KeyStoreChange> get changes => _changesController.stream;

  @override
  bool get supportsPathQueries => false;

  @override
  bool get supportsSnapshots => false;

  @override
  Future<KeyStoreSnapshot<String, AtData?, AtMetaData?>> snapshot() async {
    return _HiveBestEffortSnapshot(this);
  }

  @override
  Future<KeyStoreStats> stats() async {
    if (persistenceManager == null ||
        persistenceManager?.getBox().isOpen == false) {
      throw DataStoreException(
          'Failed to compute stats. Hive Keystore is not initialized or opened');
    }
    final box = persistenceManager!.getBox() as LazyBox;
    int total = box.length;
    int ttl = 0;
    int ttb = 0;
    DateTime? oldest;
    DateTime? newest;
    for (int i = 0; i < total; i++) {
      final raw = box.keyAt(i);
      final atData = await box.get(raw);
      final m = atData?.metaData;
      if (m == null) continue;
      if (m.ttl != null) ttl++;
      if (m.ttb != null) ttb++;
      final c = m.createdAt;
      if (c != null) {
        if (oldest == null || c.isBefore(oldest)) oldest = c;
        if (newest == null || c.isAfter(newest)) newest = c;
      }
    }
    return KeyStoreStats(
      totalKeys: total,
      ttlKeys: ttl,
      ttbKeys: ttb,
      sizeBytes: 0, // Hive doesn't expose a cheap on-disk size.
      oldestCreatedAt: oldest,
      newestCreatedAt: newest,
    );
  }

  @override
  Stream<KeyEntry<String, AtData?, AtMetaData?>> queryByPath({
    required KeyPattern keyPattern,
    required Predicate predicate,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  }) {
    throw UnsupportedError(
      'HiveSecondaryKeyStore does not support push-down path queries. '
      'Check `supportsPathQueries` before calling; on Hive, fall back '
      'to `scanKeys + getMany + in-memory filter`. SQL backends in '
      'Phase 4 flip the flag to true and execute the predicate via '
      'indexed `WHERE` clauses.',
    );
  }

  @override
  Future<R> transaction<R>(
    Future<R> Function(KeyStoreTxn<String, AtData?, AtMetaData?> txn) body,
  ) async {
    final txn = _HiveSecondaryKeyStoreTxn(this);
    final R result;
    try {
      result = await body(txn);
    } catch (_) {
      // body threw — drop buffered ops, propagate.
      rethrow;
    }
    // Body succeeded — apply buffered ops in insertion order. Each
    // applied op fires its own `changes` event via the standard
    // putAll / remove paths.
    for (final entry in txn._ops.values) {
      await entry.apply(this);
    }
    return result;
  }

  /// Bounded LRU of compiled regexes used by [getKeys]. Most callers reuse
  /// the same handful of patterns (`.*`, namespace selectors, sync filters);
  /// recompiling them per call is pure churn.
  static const int _regexCacheCapacity = 64;
  static final LinkedHashMap<String, RegExp> _regexCache = LinkedHashMap();

  static RegExp _compiledRegex(String pattern) {
    final cached = _regexCache.remove(pattern);
    if (cached != null) {
      _regexCache[pattern] = cached; // bump to most-recently-used
      return cached;
    }
    final compiled = RegExp(pattern);
    _regexCache[pattern] = compiled;
    if (_regexCache.length > _regexCacheCapacity) {
      _regexCache.remove(_regexCache.keys.first);
    }
    return compiled;
  }

  HiveSecondaryKeyStore();

  @override
  set commitLog(log) {
    _commitLog = log as HiveAtCommitLog;
  }

  @override
  get commitLog => _commitLog;

  @override
  Future<void> initialize() async {
    await _initExpiryKeysCache();
  }

  @Deprecated("Use [initialize]")

  /// Deprecated. Use [initialize]
  Future<void> init() async {
    await initialize();
  }

  Future<void> _initExpiryKeysCache() async {
    if (persistenceManager == null || !persistenceManager!.getBox().isOpen) {
      logger.severe(
          'persistence manager not initialized. skipping metadata caching');
      return;
    }
    logger.finest('Initializing _expiryKeysCache Map started');
    for (int index = 0; index < persistenceManager!.getBox().length; index++) {
      AtData atData =
          await (persistenceManager!.getBox() as LazyBox).getAt(index);
      _updateMetadataCache(Utf7.decode(atData.key), atData.metaData);
    }
    logger.finest('_expiryKeysCache initialization completed');
  }

  @override
  Future<AtData?> get(String key) async {
    key = key.toLowerCase();
    AtData? value;
    try {
      String hiveKey = HiveKeyStoreHelper.prepareKey(key);
      value = await (persistenceManager!.getBox() as LazyBox).get(hiveKey);
      // load metadata for hive_key
      // compare availableAt with time.now()
      //return only between ttl and ttb
    } on Exception catch (exception) {
      logger.severe('HiveSecondaryKeyStore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveSecondaryKeyStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    if (value == null) {
      throw KeyNotFoundException('$key does not exist in keystore',
          intent: Intent.fetchData,
          exceptionScenario: ExceptionScenario.keyNotFound);
    }
    return value;
  }

  /// hive does not support directly storing emoji characters, therefore keys
  /// are encoded in [HiveKeyStoreHelper.prepareKey] using utf7 before storing.
  @override
  Future<dynamic> put(String key, AtData? value,
      {bool skipCommit = false}) async {
    key = key.toLowerCase();
    final atKey = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKey == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }
    // ignore: prefer_typing_uninitialized_variables
    var result;

    CommitOp commitOp = CommitOp.UPDATE_ALL;

    try {
      // If does not exist, create a new key,
      // else update existing key.
      if (!isKeyExists(key)) {
        result = await create(key, value, skipCommit: skipCommit);
      } else {
        AtData? existingData = await get(key);
        String hive_key = HiveKeyStoreHelper.prepareKey(key);
        var hive_value = HiveKeyStoreHelper.prepareDataForKeystoreOperation(
            value!,
            existingAtData: existingData!,
            atSign: persistenceManager!.atsign!);
        logger.finest('hive key:$hive_key');
        logger.finest('hive value:$hive_value');
        await persistenceManager!.getBox().put(hive_key, hive_value);
        _updateMetadataCache(key, hive_value.metaData);
        if (skipCommit) {
          result = -1;
        } else {
          result = await _commitLog.commit(hive_key, commitOp);
        }
        _changesController.add(KeyUpdated(key));
      }
    } on DataStoreException {
      rethrow;
    } on Exception catch (exception) {
      logger.severe('HiveSecondaryKeyStore put exception: $exception');
      throw DataStoreException('exception in put: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveSecondaryKeyStore error: $error');
      throw DataStoreException(error.message);
    }
    return result;
  }

  /// hive does not support directly storing emoji characters, therefore keys
  /// are encoded in [HiveKeyStoreHelper.prepareKey] using utf7 before storing.
  @override
  @server
  Future<dynamic> create(String key, AtData? value,
      {bool skipCommit = false}) async {
    key = key.toLowerCase();
    final atKey = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKey == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }

    CommitOp commitOp;
    String hive_key = HiveKeyStoreHelper.prepareKey(key);
    _checkMaxLength(hive_key);
    var hive_data = HiveKeyStoreHelper.prepareDataForKeystoreOperation(
      value!,
      atSign: persistenceManager!.atsign!,
    );
    // Default commitOp to Update.
    commitOp = CommitOp.UPDATE;

    // Set CommitOp to UPDATE_ALL if any of the metadata args are not null.
    // Direct null-check chain rather than allocating a 17-element Set per call.
    final m = value.metaData;
    if (m != null &&
        (m.ttl != null ||
            m.ttb != null ||
            m.ttr != null ||
            m.isCascade != null ||
            m.isBinary != null ||
            m.isEncrypted != null ||
            m.dataSignature != null ||
            m.sharedKeyEnc != null ||
            m.pubKeyCS != null ||
            m.encoding != null ||
            m.encKeyName != null ||
            m.encAlgo != null ||
            m.ivNonce != null ||
            m.skeEncKeyName != null ||
            m.skeEncAlgo != null ||
            m.pubKeyHash != null ||
            m.immutable != null)) {
      commitOp = CommitOp.UPDATE_ALL;
    }

    try {
      await persistenceManager!.getBox().put(hive_key, hive_data);
      _updateMetadataCache(key, hive_data.metaData);
      _changesController.add(KeyAdded(key));
      if (skipCommit) {
        return -1;
      } else {
        return await _commitLog.commit(hive_key, commitOp);
      }
    } on Exception catch (exception) {
      logger.severe('HiveSecondaryKeyStore create exception: $exception');
      throw DataStoreException('exception in create: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveSecondaryKeyStore error: $error');
      throw DataStoreException(error.message);
    }
  }

  /// Returns an integer if the key to be deleted is present in keystore or cache.
  @override
  Future<int?> remove(String key, {bool skipCommit = false}) async {
    key = key.toLowerCase();

    for (final hook in preRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }

    int retVal;
    try {
      await persistenceManager!
          .getBox()
          .delete(HiveKeyStoreHelper.prepareKey(key));
      // On deleting the key, remove it from the expiryKeyCache.
      _expiryKeysCache.remove(key);
      if (skipCommit) {
        // When skipping commits, remove any existing commit entries for this
        // key from commitLog. This is critical for synchronization - during
        // sync, other commit entries for this key might be considered valid
        // if we don't remove them.
        CommitEntry? commitEntry = _commitLog.getLatestCommitEntry(key);
        if (commitEntry != null) {
          await _commitLog.commitLogKeyStore.remove(commitEntry.commitId!);
        }
        retVal = -1;
      } else {
        retVal = (await _commitLog.commit(key, CommitOp.DELETE))!;
      }
      _changesController.add(KeyRemoved(key));
    } on Exception catch (exception) {
      logger.severe('HiveSecondaryKeyStore delete exception: $exception');
      throw DataStoreException('exception in remove: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveSecondaryKeyStore delete error: $error');
      throw DataStoreException(error.message);
    }

    for (final hook in postRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }

    return retVal;
  }

  @override
  @server
  @client
  Future<bool> deleteExpiredKeys({bool skipCommit = false}) async {
    logger.finer('Removing expired keys');
    bool result = true;
    try {
      List<String> expiredKeys = await getExpiredKeys();
      if (expiredKeys.isEmpty) {
        return result;
      }

      for (String element in expiredKeys) {
        try {
          // delete entries for expired keys will not be added to the commitLog
          // Removal of expired keys will be handled on the client side
          await remove(element, skipCommit: skipCommit);
        } on KeyNotFoundException {
          continue;
        }
      }
      result = true;
    } on Exception catch (e) {
      result = false;
      logger.severe('Exception in deleteExpired keys: ${e.toString()}');
      throw DataStoreException(
          'exception in deleteExpiredKeys: ${e.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveSecondaryKeyStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }

    return result;
  }

  @override
  @server
  Future<List<String>> getExpiredKeys() async {
    List<String> expiredKeys = <String>[];
    final now = DateTime.timestamp();
    for (String key in _expiryKeysCache.keys) {
      if (_isExpired(key, now: now)) {
        expiredKeys.add(key);
      }
    }
    return expiredKeys;
  }

  /// Returns list of keys from the secondary storage.
  /// @param - regex : Optional parameter to filter keys on regular expression.
  /// @return - `List<String>` : List of keys from secondary storage.
  @override
  List<String> getKeys({String? regex}) {
    if (persistenceManager == null ||
        persistenceManager?.getBox().isOpen == false) {
      throw DataStoreException(
          'Failed to fetch keys. Hive Keystore is not initialized or opened');
    }
    List<String> keys = <String>[];
    regex ??= '.*';
    final RegExp regExp;
    try {
      regExp = _compiledRegex(regex);
    } on FormatException catch (exception) {
      logger.severe('Invalid regular expression : $regex');
      throw InvalidSyntaxException('Invalid syntax ${exception.toString()}');
    }

    // Capture `now` once outside the loop and pass it into the availability
    // check so each key doesn't allocate two DateTime objects.
    final now = DateTime.timestamp();
    String key;
    try {
      for (int index = 0;
          index < persistenceManager!.getBox().length;
          index++) {
        key = Utf7.decode(persistenceManager!.getBox().keyAt(index));
        if (_isKeyAvailable(key, now: now) && regExp.hasMatch(key)) {
          keys.add(key);
        }
      }
    } on Exception catch (exception) {
      logger.severe(
          'HiveSecondaryKeyStore getKeys exception: ${exception.toString()}');
      throw DataStoreException('exception in getKeys: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveSecondaryKeyStore get error: $error');
      _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    return keys;
  }

  @override
  Future<AtMetaData?> getMeta(String key) async {
    // The earlier version returns "null" when key is not present in the
    // cache map. To preserve the existing behaviour, returning "null"
    // when KeyNotFoundException is thrown.
    try {
      return (await get(key.toLowerCase()))?.metaData;
    } on KeyNotFoundException {
      return null;
    }
  }

  @override
  @client
  Future<int?> putAll(String key, AtData? value, AtMetaData? metadata) async {
    key = key.toLowerCase();
    final atKeyType = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKeyType == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }
    try {
      int? result;
      String hive_key = HiveKeyStoreHelper.prepareKey(key);
      _checkMaxLength(hive_key);
      AtData? existingData;
      if (isKeyExists(key)) {
        existingData = await get(key);
      }
      value!.metaData = AtMetadataBuilder(
              newAtMetaData: metadata!,
              existingMetaData: existingData?.metaData,
              atSign: persistenceManager!.atsign!)
          .build();
      await persistenceManager!.getBox().put(hive_key, value);
      _updateMetadataCache(key, value.metaData);
      result = await _commitLog.commit(hive_key, CommitOp.UPDATE_ALL);
      _changesController
          .add(existingData == null ? KeyAdded(key) : KeyUpdated(key));
      return result;
    } on HiveError catch (error) {
      logger.severe('HiveSecondaryKeyStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<int?> putMeta(String key, AtMetaData? metadata) async {
    key = key.toLowerCase();
    try {
      String hive_key = HiveKeyStoreHelper.prepareKey(key);
      AtData? existingData;
      if (isKeyExists(key)) {
        existingData = await get(key);
      }
      // putMeta is intended to updates only the metadata of a key.
      // So, fetch the value from the existing key and set the same value.
      AtData newData = existingData ?? AtData();
      newData.metaData = AtMetadataBuilder(
              newAtMetaData: metadata!,
              existingMetaData: existingData?.metaData,
              atSign: persistenceManager!.atsign!)
          .build();

      await persistenceManager!.getBox().put(hive_key, newData);
      _updateMetadataCache(key, newData.metaData);
      var result = await _commitLog.commit(hive_key, CommitOp.UPDATE_META);
      _changesController
          .add(existingData == null ? KeyAdded(key) : KeyUpdated(key));
      return result;
    } on HiveError catch (error) {
      logger.severe('HiveSecondaryKeyStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  /// Returns true if key exists in [HiveSecondaryKeyStore]. false otherwise.
  @override
  @server
  bool isKeyExists(String key) {
    key = key.toLowerCase();
    return persistenceManager!
        .getBox()
        .containsKey(HiveKeyStoreHelper.prepareKey(key));
  }

  @override
  Future<bool> exists(String key) async => isKeyExists(key);

  @override
  Future<int> removeMany(List<String> keys, {bool skipCommit = false}) async {
    if (keys.isEmpty) return 0;
    if (persistenceManager == null ||
        persistenceManager?.getBox().isOpen == false) {
      throw DataStoreException(
          'Failed to bulk-delete. Hive Keystore is not initialized or opened');
    }
    final box = persistenceManager!.getBox();

    // 1. Identify which input keys are actually present. We dedup by
    //    lowercased form so duplicates in [keys] don't double-count.
    final present = <String>{};
    final preparedToDelete = <String>[];
    for (final raw in keys) {
      final lowered = raw.toLowerCase();
      if (present.contains(lowered)) continue;
      final hiveKey = HiveKeyStoreHelper.prepareKey(lowered);
      if (!box.containsKey(hiveKey)) continue;
      present.add(lowered);
      preparedToDelete.add(hiveKey);
    }
    if (present.isEmpty) return 0;

    // 2. preRemoveHooks per present key.
    for (final lowered in present) {
      for (final hook in preRemoveHooks) {
        await hook(lowered, skipCommit: skipCommit);
      }
    }

    try {
      // 3. Single batched box delete.
      await box.deleteAll(preparedToDelete);

      // 4. Per-key cache + commit-log bookkeeping.
      for (final lowered in present) {
        _expiryKeysCache.remove(lowered);
        if (skipCommit) {
          // Match remove(): purge any existing commit entries for this
          // key, otherwise sync may consider them valid post-delete.
          CommitEntry? commitEntry = _commitLog.getLatestCommitEntry(lowered);
          if (commitEntry != null) {
            await _commitLog.commitLogKeyStore.remove(commitEntry.commitId!);
          }
        } else {
          await _commitLog.commit(lowered, CommitOp.DELETE);
        }
      }
    } on Exception catch (exception) {
      logger.severe('HiveSecondaryKeyStore removeMany exception: $exception');
      throw DataStoreException(
          'exception in removeMany: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveSecondaryKeyStore removeMany error: $error');
      throw DataStoreException(error.message);
    }

    // 5. postRemoveHooks per present key.
    for (final lowered in present) {
      for (final hook in postRemoveHooks) {
        await hook(lowered, skipCommit: skipCommit);
      }
    }

    // 6. Emit a KeyRemoved event per actually-removed key.
    for (final lowered in present) {
      _changesController.add(KeyRemoved(lowered));
    }

    return present.length;
  }

  @override
  Future<Map<String, AtData?>> getMany(List<String> keys) async {
    if (persistenceManager == null ||
        persistenceManager?.getBox().isOpen == false) {
      throw DataStoreException(
          'Failed to bulk-fetch keys. Hive Keystore is not initialized or opened');
    }
    final box = persistenceManager!.getBox() as LazyBox;
    final result = <String, AtData?>{};
    for (final raw in keys) {
      final lowered = raw.toLowerCase();
      final hiveKey = HiveKeyStoreHelper.prepareKey(lowered);
      if (!box.containsKey(hiveKey)) continue;
      try {
        result[lowered] = await box.get(hiveKey);
      } on Exception catch (e) {
        logger.severe('HiveSecondaryKeyStore getMany exception for "$raw": $e');
        throw DataStoreException('exception in getMany: ${e.toString()}');
      } on HiveError catch (error) {
        logger.severe('HiveSecondaryKeyStore getMany error: $error');
        await _restartHiveBox(error);
        throw DataStoreException(error.message);
      }
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
    if (persistenceManager == null ||
        persistenceManager?.getBox().isOpen == false) {
      throw DataStoreException(
          'Failed to scan keys. Hive Keystore is not initialized or opened');
    }

    if (orderBy == null || orderBy == OrderByKey.byKey) {
      yield* _scanKeysOrdered(
        pattern,
        includeExpired: includeExpired,
        sortByKey: orderBy == OrderByKey.byKey,
        limit: limit,
        skip: skip,
      );
    } else {
      yield* _scanKeysOrderedByMetadata(
        pattern,
        includeExpired: includeExpired,
        orderBy: orderBy,
        limit: limit,
        skip: skip,
      );
    }
  }

  /// Stream matching keys in either insertion order
  /// (`sortByKey: false`) or lexicographic key order
  /// (`sortByKey: true`). [skip] and [limit] are applied AFTER
  /// pattern + expiry filtering.
  Stream<String> _scanKeysOrdered(
    KeyPattern pattern, {
    required bool includeExpired,
    required bool sortByKey,
    int? limit,
    int? skip,
  }) async* {
    final now = DateTime.timestamp();
    final box = persistenceManager!.getBox();
    final length = box.length;
    Iterable<String> generate() sync* {
      for (int index = 0; index < length; index++) {
        final raw = box.keyAt(index);
        final String key;
        try {
          key = Utf7.decode(raw);
        } on Exception {
          continue;
        }
        if (!includeExpired && !_isKeyAvailable(key, now: now)) continue;
        if (!_matchesPattern(key, pattern)) continue;
        yield key;
      }
    }

    Iterable<String> seq = generate();
    if (sortByKey) {
      // Materialise to sort lexicographically.
      seq = seq.toList()..sort();
    }
    final skipN = skip ?? 0;
    int yielded = 0;
    int seen = 0;
    for (final k in seq) {
      if (seen < skipN) {
        seen++;
        continue;
      }
      if (limit != null && yielded >= limit) break;
      yield k;
      yielded++;
    }
  }

  /// Stream matching keys ordered by an AtMetaData field
  /// (`createdAt` or `expiresAt`). Materialises (key, sortField)
  /// tuples for every match, sorts, then applies skip+limit.
  /// Cost is O(N log N) on Hive — one LazyBox await per match.
  Stream<String> _scanKeysOrderedByMetadata(
    KeyPattern pattern, {
    required bool includeExpired,
    required OrderByKey orderBy,
    int? limit,
    int? skip,
  }) async* {
    final now = DateTime.timestamp();
    final box = persistenceManager!.getBox() as LazyBox;
    final tuples = <_KeyWithSortField>[];
    final length = box.length;
    for (int index = 0; index < length; index++) {
      final raw = box.keyAt(index);
      final String key;
      try {
        key = Utf7.decode(raw);
      } on Exception {
        continue;
      }
      if (!includeExpired && !_isKeyAvailable(key, now: now)) continue;
      if (!_matchesPattern(key, pattern)) continue;
      final atData = await box.get(raw);
      DateTime? sortField;
      switch (orderBy) {
        case OrderByKey.byCreatedAt:
          sortField = atData?.metaData?.createdAt;
          break;
        case OrderByKey.byExpiresAt:
          sortField = atData?.metaData?.expiresAt;
          break;
        case OrderByKey.byKey:
          // Unreachable — handled by the byKey path above.
          throw StateError('byKey should not reach _scanKeysOrderedByMetadata');
      }
      tuples.add(_KeyWithSortField(key, sortField));
    }
    // Sort: nulls go last (no-expiry, no-createdAt entries).
    tuples.sort((a, b) {
      if (a.sortField == null && b.sortField == null) return 0;
      if (a.sortField == null) return 1;
      if (b.sortField == null) return -1;
      return a.sortField!.compareTo(b.sortField!);
    });

    final skipN = skip ?? 0;
    int yielded = 0;
    for (int i = skipN; i < tuples.length; i++) {
      if (limit != null && yielded >= limit) break;
      yield tuples[i].key;
      yielded++;
    }
  }

  /// Returns `true` iff [keyString] matches every non-null field on
  /// [pattern]. A pattern with no non-null fields matches every key.
  /// Malformed atKeys (no `@`, contains a space) match only when the
  /// pattern is unrestricted — they have no parseable structure.
  bool _matchesPattern(String keyString, KeyPattern pattern) {
    if (pattern.isUnrestricted) return true;
    final AtKey atKey;
    try {
      atKey = AtKey.fromString(keyString);
    } on Exception {
      // Malformed key — has no structured fields to filter on.
      // Skip rather than throw so a single bad row doesn't break a
      // whole scan.
      return false;
    }
    if (pattern.sharedBy != null &&
        !_atSignEquals(atKey.sharedBy, pattern.sharedBy!)) {
      return false;
    }
    if (pattern.sharedWith != null &&
        !_atSignEquals(atKey.sharedWith, pattern.sharedWith!)) {
      return false;
    }
    if (pattern.namespace != null && atKey.namespace != pattern.namespace) {
      return false;
    }
    if (pattern.idPrefix != null && !atKey.key.startsWith(pattern.idPrefix!)) {
      return false;
    }
    return true;
  }

  /// Case-insensitive atSign comparison that tolerates the leading
  /// `@` being present on either, neither, or both sides.
  bool _atSignEquals(String? actual, String expected) {
    if (actual == null) return false;
    final a = actual.startsWith('@') ? actual.substring(1) : actual;
    final e = expected.startsWith('@') ? expected.substring(1) : expected;
    return a.toLowerCase() == e.toLowerCase();
  }

  /// Certain keys created on one atsign server may be cached in another atsign server.
  /// Restrict key length to [_maxKeyLengthWithoutCached] if is not a cached key
  void _checkMaxLength(String key) {
    int maxLength =
        key.startsWith('cached:') ? maxKeyLength : maxKeyLengthWithoutCached;
    if (key.length > maxLength) {
      throw DataStoreException(
        'key length ${key.length} is greater than max allowed $maxLength chars',
      );
    }
  }

  ///Restarts the hive box.
  Future<void> _restartHiveBox(Error e) async {
    // If hive box closed, reopen the box.
    if (e is HiveError && !persistenceManager!.getBox().isOpen) {
      logger.info('Hive box closed. Restarting the hive box');
      await persistenceManager!
          .openBox(AtUtils.getShaForAtSign(persistenceManager!.atsign!));
    }
  }

  /// If a key is expired, returns true; else returns false.
  bool _isExpired(key, {DateTime? now}) {
    // If key is not present in _expiryKeyCache, it implies that key does not
    // have TTL set. So, the key will never expire. Return false.
    if (!_expiryKeysCache.containsKey(key) ||
        _expiryKeysCache[key]![expiresAt] == null) {
      return false;
    }
    return _expiryKeysCache[key]![expiresAt]!
        .isBefore(now ?? DateTime.timestamp());
  }

  /// Return true if the key is active
  bool _isBorn(key, {DateTime? now}) {
    // If key is not present in _expiryKeyCache, it implies that key does not
    // have TTB set. So, the key will be active. Return true.
    if (!_expiryKeysCache.containsKey(key) ||
        _expiryKeysCache[key]![availableAt] == null) {
      return true;
    }
    return _expiryKeysCache[key]![availableAt]!
        .isBefore(now ?? DateTime.timestamp());
  }

  /// Verifies if the given key is active.
  /// If key is active, returns "true", else returns "false"
  bool _isKeyAvailable(key, {DateTime? now}) {
    // If _expiryKeyCache does not contain the key, then it implies
    // that key does not have TTL or TTB set.
    // So, the key never expires; return true.
    if (!_expiryKeysCache.containsKey(key)) {
      return true;
    }
    final t = now ?? DateTime.timestamp();
    return !_isExpired(key, now: t) && _isBorn(key, now: t);
  }

  /// Adds an entry where key is AtKey and value is Map containing the "expiresAt"
  /// and "availableAt" into the [_expiryKeysCache] map.
  ///
  /// Adds only the keys whose TTL or TTB is set in the metadata; otherwise ignored.
  void _updateMetadataCache(String key, AtMetaData? atMetaData) {
    // If the metadata of a key does not have TTL or TTB set, then the key is active forever.
    // Do not add it to _expiryKeyCache.
    if (atMetaData == null ||
        (atMetaData.ttb == null && atMetaData.ttl == null)) {
      // On an existing key, if TTL or TTB is unset, then TTL/TTB value will be null.
      // Therefore, the new metadata will not be updated in the _expiryKeyCache.
      // To prevent the stale metadata being returned from getMeta, remove the entry from
      // _expiryKeyCache
      _expiryKeysCache.remove(key);
      return;
    }
    // Setting TTL/TTB to 0 (Zero) implies to unset the metadata.
    // Therefore, the key will be active forever. Hence remove the existing key
    // (if any)from expiryKeyCache
    if ((atMetaData.ttl == null && atMetaData.ttb == 0) ||
        (atMetaData.ttb == null && atMetaData.ttl == 0)) {
      _expiryKeysCache.remove(key);
      return;
    }
    _expiryKeysCache[key] = {
      availableAt: atMetaData.availableAt,
      expiresAt: atMetaData.expiresAt
    };
  }

  @visibleForTesting
  HashMap<String, Map<String, DateTime?>> getExpiryKeysCache() {
    return _expiryKeysCache;
  }

  /// Drop every entry from the underlying box AND from the
  /// in-memory caches (`_expiryKeysCache`). Used by
  /// [AtPersistenceBundle.clear] for cheap test isolation —
  /// production code uses [close] instead.
  Future<void> clear() async {
    await persistenceManager?.getBox().clear();
    _expiryKeysCache.clear();
  }
}

/// (key, sortField) pair used by `_scanKeysOrderedByMetadata`.
class _KeyWithSortField {
  final String key;
  final DateTime? sortField;
  _KeyWithSortField(this.key, this.sortField);
}

/// A buffered op recorded against a [_HiveSecondaryKeyStoreTxn].
/// Applied to the underlying [HiveSecondaryKeyStore] at commit
/// time, in insertion order.
abstract class _BufferedOp {
  Future<void> apply(HiveSecondaryKeyStore store);
}

class _BufferedPut implements _BufferedOp {
  final String key;
  final AtData? value;
  final AtMetaData? metadata;
  _BufferedPut(this.key, this.value, this.metadata);

  @override
  Future<void> apply(HiveSecondaryKeyStore store) async {
    await store.putAll(key, value, metadata);
  }
}

class _BufferedRemove implements _BufferedOp {
  final String key;
  _BufferedRemove(this.key);

  @override
  Future<void> apply(HiveSecondaryKeyStore store) async {
    await store.remove(key);
  }
}

class _HiveSecondaryKeyStoreTxn
    implements KeyStoreTxn<String, AtData?, AtMetaData?> {
  final HiveSecondaryKeyStore _store;

  /// Buffered ops keyed by lowercased key. The latest op for a
  /// given key wins (a put-then-remove leaves only the remove,
  /// matching what would happen if these ops were applied in
  /// sequence with no transaction).
  final Map<String, _BufferedOp> _ops = <String, _BufferedOp>{};

  _HiveSecondaryKeyStoreTxn(this._store);

  @override
  Future<void> put(String key, AtData? value, AtMetaData? metadata) async {
    _ops[key.toLowerCase()] = _BufferedPut(key, value, metadata);
  }

  @override
  Future<void> remove(String key) async {
    _ops[key.toLowerCase()] = _BufferedRemove(key);
  }

  @override
  Future<AtData?> get(String key) async {
    final lowered = key.toLowerCase();
    final buffered = _ops[lowered];
    if (buffered is _BufferedPut) return buffered.value;
    if (buffered is _BufferedRemove) return null;
    // Fall through to the underlying store. get() throws on absent;
    // translate to a tolerant `null` return so transaction reads
    // mirror the buffered shape.
    try {
      return await _store.get(key);
    } on KeyNotFoundException {
      return null;
    }
  }

  @override
  Future<bool> exists(String key) async {
    final lowered = key.toLowerCase();
    final buffered = _ops[lowered];
    if (buffered is _BufferedPut) return true;
    if (buffered is _BufferedRemove) return false;
    return _store.isKeyExists(key);
  }
}

/// Best-effort snapshot for Hive. Hive has no MVCC, so reads
/// through this handle observe live state — there is no real
/// isolation. Documented in the abstract; consumers that require
/// isolation gate on `supportsSnapshots`.
class _HiveBestEffortSnapshot
    implements KeyStoreSnapshot<String, AtData?, AtMetaData?> {
  final HiveSecondaryKeyStore _store;
  bool _released = false;

  _HiveBestEffortSnapshot(this._store);

  @override
  Future<AtData?> get(String key) async {
    if (_released) {
      throw StateError('Snapshot has been released');
    }
    try {
      return await _store.get(key);
    } on KeyNotFoundException {
      return null;
    }
  }

  @override
  Stream<String> scanKeys(KeyPattern pattern) {
    if (_released) {
      throw StateError('Snapshot has been released');
    }
    return _store.scanKeys(pattern);
  }

  @override
  Future<void> release() async {
    _released = true;
  }
}
