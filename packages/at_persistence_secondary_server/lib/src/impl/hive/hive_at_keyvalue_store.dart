// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_base.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_keystore_helper.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

class HiveAtKeyValueStore
    with HiveBase<AtData?>
    implements AtKeyValueStore<String, AtData, AtMetaData?> {
  final AtSignLogger logger = AtSignLogger('HiveAtKeyValueStore');
  final String expiresAt = 'expiresAt';
  final String availableAt = 'availableAt';
  static const int maxKeyLength = 255;
  static const int maxKeyLengthWithoutCached = 248;

  /// The atSign this keystore serves. Used for the per-atSign Hive
  /// box name and as the audit value on `AtMetaData.createdBy` /
  /// `updatedBy`.
  final String atSign;

  HiveAtKeyValueStore(this.atSign);

  /// The commit log for this keystore, or `null` for a commit-log-free
  /// (client-side) keystore. Server bundles wire one in via
  /// [commitLog]=; client bundles leave it `null`, in which case every
  /// write returns `null` and [compact] yields nothing.
  HiveAtCommitLog? _commitLog;

  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      preRemoveHooks = [];
  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
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
  Future<AtKeyValueStoreSnapshot<String, AtData, AtMetaData?>>
      snapshot() async {
    return _HiveBestEffortSnapshot(this);
  }

  @override
  Future<KeyStoreStats> stats() async {
    if (!getBox().isOpen) {
      throw DataStoreException(
          'Failed to compute stats. Hive Keystore is not initialized or opened');
    }
    final box = getBox() as LazyBox;
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
  Stream<KeyEntry<String, AtData, AtMetaData?>> queryByPath({
    required KeyPattern keyPattern,
    required Predicate predicate,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  }) {
    throw UnsupportedError(
      'HiveAtKeyValueStore does not support push-down path queries. '
      'Check `supportsPathQueries` before calling; on Hive, fall back '
      'to `scanKeys + getMany + in-memory filter`. A future SQL '
      'backend flips the flag to true and executes the predicate via '
      'indexed `WHERE` clauses.',
    );
  }

  @override
  Future<R> transaction<R>(
    Future<R> Function(KeyStoreTxn<String, AtData, AtMetaData?> txn) body,
  ) async {
    final txn = _HiveAtKeyValueStoreTxn(this);
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

  @override
  set commitLog(log) {
    _commitLog = log as HiveAtCommitLog?;
  }

  @override
  get commitLog => _commitLog;

  /// Compact this keystore by delegating to the internal commit
  /// log's [HiveAtCommitLog.compact]. The keystore itself doesn't
  /// have its own compaction algorithm — the commit log is the
  /// thing that accumulates entries faster than it can shed them.
  ///
  /// A commit-log-free (client-side) keystore has nothing to
  /// compact: the call is a no-op that yields nothing.
  @override
  Stream<int> compact(bool dryRun) {
    return _commitLog?.compact(dryRun) ?? Stream<int>.empty();
  }

  @override
  Future<void> initialize() async {
    try {
      if (!Hive.isAdapterRegistered(AtDataAdapter().typeId)) {
        Hive.registerAdapter(AtDataAdapter());
      }
      if (!Hive.isAdapterRegistered(AtMetaDataAdapter().typeId)) {
        Hive.registerAdapter(AtMetaDataAdapter());
      }
      if (!Hive.isAdapterRegistered(PublicKeyHashAdapter().typeId)) {
        Hive.registerAdapter(PublicKeyHashAdapter());
      }
      final secret = await _getHiveSecretFromFile(atSign, storagePath);
      await openBox(AtUtils.getShaForAtSign(atSign), hiveSecret: secret);
    } on Exception catch (e) {
      logger.severe('HiveAtKeyValueStore.initialize exception: $e');
      throw DataStoreException(
          'Exception initializing secondary keystore: ${e.toString()}');
    }
    await _initExpiryKeysCache();
  }

  Future<List<int>?> _getHiveSecretFromFile(
      String atsign, String storagePath) async {
    List<int>? secretAsUint8List;
    try {
      atsign = atsign.trim().toLowerCase();
      final fileName = '${AtUtils.getShaForAtSign(atsign)}.hash';
      final filePath = '$storagePath/$fileName';
      String hiveSecretString;
      final exists = File(filePath).existsSync();
      if (exists) {
        hiveSecretString = File(filePath).readAsStringSync();
        if (hiveSecretString.isEmpty) {
          secretAsUint8List = Hive.generateSecureKey();
          hiveSecretString = String.fromCharCodes(secretAsUint8List);
          File(filePath).writeAsStringSync(hiveSecretString);
        } else {
          secretAsUint8List = Uint8List.fromList(hiveSecretString.codeUnits);
        }
      } else {
        secretAsUint8List = Hive.generateSecureKey();
        hiveSecretString = String.fromCharCodes(secretAsUint8List);
        final newFile = await File(filePath).create(recursive: true);
        newFile.writeAsStringSync(hiveSecretString);
      }
    } on Exception catch (exception) {
      logger.severe('getHiveSecretFromFile exception: $exception');
    } catch (error) {
      logger.severe('getHiveSecretFromFile caught error: $error');
    }
    return secretAsUint8List;
  }

  Future<void> _initExpiryKeysCache() async {
    if (!getBox().isOpen) {
      logger.severe('keystore box not open; skipping metadata caching');
      return;
    }
    logger.finest('Initializing _expiryKeysCache Map started');
    final box = getBox() as LazyBox;
    for (int index = 0; index < box.length; index++) {
      final hiveKey = box.keyAt(index);
      AtData atData = await box.getAt(index);
      atData.key = hiveKey;
      _updateMetadataCache(Utf7.decode(hiveKey), atData.metaData);
    }
    logger.finest('_expiryKeysCache initialization completed');
  }

  @override
  Future<AtData?> get(String key) async {
    key = key.toLowerCase();
    AtData? value;
    try {
      String hiveKey = HiveKeyStoreHelper.prepareKey(key);
      value = await (getBox() as LazyBox).get(hiveKey);
      value?.key = hiveKey;
      // load metadata for hive_key
      // compare availableAt with time.now()
      //return only between ttl and ttb
    } on Exception catch (exception) {
      logger.severe('HiveAtKeyValueStore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveAtKeyValueStore get error: $error');
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
  Future<int?> put(String key, AtData value,
      {bool skipCommit = false,
      AtAssertedTimestamps? assertedTimestamps}) async {
    key = key.toLowerCase();
    final atKey = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKey == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }
    int? result;

    CommitOp commitOp = CommitOp.UPDATE_ALL;

    try {
      // If does not exist, create a new key,
      // else update existing key.
      if (!await exists(key)) {
        result = await create(key, value,
            skipCommit: skipCommit, assertedTimestamps: assertedTimestamps);
      } else {
        AtData? existingData = await get(key);
        String hive_key = HiveKeyStoreHelper.prepareKey(key);
        var hive_value = HiveKeyStoreHelper.prepareDataForKeystoreOperation(
            value,
            existingAtData: existingData!,
            atSign: atSign,
            asserted: assertedTimestamps);
        logger.finest('hive key:$hive_key');
        logger.finest('hive value:$hive_value');
        await getBox().put(hive_key, hive_value);
        _updateMetadataCache(key, hive_value.metaData);
        if (skipCommit) {
          // A skipCommit write leaves no trace in the commit log: as
          // well as writing no entry, purge the key's previous entry —
          // sync would otherwise keep serving a stale entry for a
          // record whose latest change was deliberately uncommitted.
          // (No-op on a commit-log-free keystore.)
          await _commitLog?.removeEntryFor(hive_key);
          result = -1;
        } else {
          // `_commitLog` is null on a commit-log-free keystore — the
          // write still succeeds, it just produces no sequence number.
          result = await _commitLog?.commit(hive_key, commitOp,
              opTime: assertedTimestamps?.updatedAt);
        }
        _changesController.add(KeyUpdated(key));
      }
    } on DataStoreException {
      rethrow;
    } on Exception catch (exception) {
      logger.severe('HiveAtKeyValueStore put exception: $exception');
      throw DataStoreException('exception in put: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveAtKeyValueStore error: $error');
      throw DataStoreException(error.message);
    }
    return result;
  }

  /// hive does not support directly storing emoji characters, therefore keys
  /// are encoded in [HiveKeyStoreHelper.prepareKey] using utf7 before storing.
  @override
  @server
  Future<int?> create(String key, AtData value,
      {bool skipCommit = false,
      AtAssertedTimestamps? assertedTimestamps}) async {
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
      value,
      atSign: atSign,
      asserted: assertedTimestamps,
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
      await getBox().put(hive_key, hive_data);
      _updateMetadataCache(key, hive_data.metaData);
      _changesController.add(KeyAdded(key));
      if (skipCommit) {
        // Purge any previous entry for this key, matching put/remove's
        // skipCommit behaviour. (No-op on a commit-log-free keystore.)
        await _commitLog?.removeEntryFor(hive_key);
        return -1;
      } else {
        // `_commitLog` is null on a commit-log-free keystore — the
        // write still succeeds, it just produces no sequence number.
        return await _commitLog?.commit(hive_key, commitOp,
            opTime: assertedTimestamps?.updatedAt);
      }
    } on Exception catch (exception) {
      logger.severe('HiveAtKeyValueStore create exception: $exception');
      throw DataStoreException('exception in create: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveAtKeyValueStore error: $error');
      throw DataStoreException(error.message);
    }
  }

  /// Writes [value] verbatim — no metadata builder, no commit-log
  /// append, no change event. See [AtKeyValueStore.restore]. Used by
  /// the persistence migrator to reproduce a source keystore's
  /// records exactly (preserving createdAt/updatedAt/version and
  /// every other field).
  @override
  Future<void> restore(String key, AtData value) async {
    key = key.toLowerCase();
    final atKey = AtKey.getKeyType(key, enforceNameSpace: false);
    if (atKey == KeyType.invalidKey) {
      logger.warning('Key $key is invalid');
      throw InvalidAtKeyException('Key $key is invalid');
    }
    String hiveKey = HiveKeyStoreHelper.prepareKey(key);
    _checkMaxLength(hiveKey);
    try {
      await getBox().put(hiveKey, value);
      _updateMetadataCache(key, value.metaData);
    } on Exception catch (exception) {
      logger.severe('HiveAtKeyValueStore restore exception: $exception');
      throw DataStoreException('exception in restore: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveAtKeyValueStore error: $error');
      throw DataStoreException(error.message);
    }
  }

  /// Returns an integer if the key to be deleted is present in keystore or cache.
  @override
  Future<int?> remove(String key,
      {bool skipCommit = false, DateTime? deletedAt}) async {
    key = key.toLowerCase();

    for (final hook in preRemoveHooks) {
      await hook(key, skipCommit: skipCommit);
    }

    int? retVal;
    try {
      // The prepared (utf7-encoded) form is the one every commit-log call
      // takes — commit() and removeEntryFor() both decode internally.
      // Passing the raw key here would get decoded a second time, which
      // mangles keys containing utf7 escape sequences.
      String hiveKey = HiveKeyStoreHelper.prepareKey(key);
      await getBox().delete(hiveKey);
      // On deleting the key, remove it from the expiryKeyCache.
      _expiryKeysCache.remove(key);
      final commitLog = _commitLog;
      if (skipCommit) {
        // When skipping commits, remove any existing commit entry for this
        // key from commitLog. This is critical for synchronization - during
        // sync, other commit entries for this key might be considered valid
        // if we don't remove them. (No-op on a commit-log-free keystore.)
        await commitLog?.removeEntryFor(hiveKey);
        retVal = -1;
      } else {
        // `commitLog` is null on a commit-log-free keystore — the
        // delete still succeeds, it just produces no sequence number.
        retVal = await commitLog?.commit(hiveKey, CommitOp.DELETE,
            opTime: deletedAt);
      }
      _changesController.add(KeyRemoved(key));
    } on Exception catch (exception) {
      logger.severe('HiveAtKeyValueStore delete exception: $exception');
      throw DataStoreException('exception in remove: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveAtKeyValueStore delete error: $error');
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
  Future<bool> deleteExpiredKeys() async {
    logger.finer('Removing expired keys');
    bool result = true;
    try {
      List<String> expiredKeys = await (await getExpiredKeys()).toList();
      if (expiredKeys.isEmpty) {
        return result;
      }

      for (String element in expiredKeys) {
        try {
          // delete entries for expired keys will not be added to the commitLog
          // Removal of expired keys will be handled on the client side
          await remove(element, skipCommit: true);
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
      logger.severe('HiveAtKeyValueStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }

    return result;
  }

  @override
  @server
  Future<Stream<String>> getExpiredKeys() async {
    List<String> expiredKeys = <String>[];
    final now = DateTime.timestamp();
    for (String key in _expiryKeysCache.keys) {
      if (_isExpired(key, now: now)) {
        expiredKeys.add(key);
      }
    }
    return Stream.fromIterable(expiredKeys);
  }

  @override
  @server
  @client
  Future<DateTime?> nextExpiresAt() async {
    DateTime? min;
    for (final fields in _expiryKeysCache.values) {
      final exp = fields[expiresAt];
      if (exp == null) continue;
      if (min == null || exp.isBefore(min)) min = exp;
    }
    return min;
  }

  @override
  @server
  @client
  Future<Stream<String>> peekExpired({DateTime? asOf, int? limit}) async {
    final cutoff = asOf ?? DateTime.timestamp();
    return Stream.fromIterable(
        _collectAscending(expiresAt, limit, (t) => !t.isAfter(cutoff)));
  }

  @override
  @server
  @client
  Future<DateTime?> nextAvailableAt({DateTime? asOf}) async {
    final cutoff = asOf ?? DateTime.timestamp();
    DateTime? min;
    for (final fields in _expiryKeysCache.values) {
      final avail = fields[availableAt];
      // Strictly after the cutoff: already-born keys are excluded.
      if (avail == null || !avail.isAfter(cutoff)) continue;
      if (min == null || avail.isBefore(min)) min = avail;
    }
    return min;
  }

  @override
  @server
  @client
  Future<Stream<String>> peekNewlyAvailable({
    required DateTime since,
    DateTime? asOf,
    int? limit,
  }) async {
    final cutoff = asOf ?? DateTime.timestamp();
    return Stream.fromIterable(_collectAscending(
        availableAt, limit, (t) => t.isAfter(since) && !t.isAfter(cutoff)));
  }

  /// Walks `_expiryKeysCache`, keeps keys whose [field] value
  /// satisfies [matches], and returns up to [limit] of them in
  /// ascending-[field] order.
  List<String> _collectAscending(
      String field, int? limit, bool Function(DateTime) matches) {
    if (limit != null && limit <= 0) return const [];
    final hits = <MapEntry<String, DateTime>>[];
    _expiryKeysCache.forEach((key, fields) {
      final t = fields[field];
      if (t != null && matches(t)) hits.add(MapEntry(key, t));
    });
    hits.sort((a, b) => a.value.compareTo(b.value));
    final limited = limit == null ? hits : hits.take(limit);
    return limited.map((e) => e.key).toList();
  }

  /// Returns list of keys from the secondary storage.
  /// @param - regex : Optional parameter to filter keys on regular expression.
  /// @return - `List<String>` : List of keys from secondary storage.
  @override
  Future<Stream<String>> getKeys({String? regex}) async {
    if (!getBox().isOpen) {
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
      for (int index = 0; index < getBox().length; index++) {
        key = Utf7.decode(getBox().keyAt(index));
        if (_isKeyAvailable(key, now: now) && regExp.hasMatch(key)) {
          keys.add(key);
        }
      }
    } on Exception catch (exception) {
      logger.severe(
          'HiveAtKeyValueStore getKeys exception: ${exception.toString()}');
      throw DataStoreException('exception in getKeys: ${exception.toString()}');
    } on HiveError catch (error) {
      logger.severe('HiveAtKeyValueStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
    return Stream.fromIterable(keys);
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
  Future<int?> putAll(String key, AtData value, AtMetaData? metadata) async {
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
      if (await exists(key)) {
        existingData = await get(key);
      }
      value.metaData = AtMetadataBuilder(
              newAtMetaData: metadata!,
              existingMetaData: existingData?.metaData,
              atSign: atSign)
          .build();
      await getBox().put(hive_key, value);
      _updateMetadataCache(key, value.metaData);
      // `_commitLog` is null on a commit-log-free keystore — the write
      // still succeeds, it just produces no sequence number.
      result = await _commitLog?.commit(hive_key, CommitOp.UPDATE_ALL);
      _changesController
          .add(existingData == null ? KeyAdded(key) : KeyUpdated(key));
      return result;
    } on HiveError catch (error) {
      logger.severe('HiveAtKeyValueStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  @override
  Future<int?> putMeta(String key, AtMetaData? metadata,
      {bool skipCommit = false,
      AtAssertedTimestamps? assertedTimestamps}) async {
    key = key.toLowerCase();
    try {
      String hive_key = HiveKeyStoreHelper.prepareKey(key);
      AtData? existingData;
      if (await exists(key)) {
        existingData = await get(key);
      }
      // putMeta is intended to updates only the metadata of a key.
      // So, fetch the value from the existing key and set the same value.
      AtData newData = existingData ?? AtData();
      newData.metaData = AtMetadataBuilder(
              newAtMetaData: metadata!,
              existingMetaData: existingData?.metaData,
              atSign: atSign,
              asserted: assertedTimestamps)
          .build();

      await getBox().put(hive_key, newData);
      _updateMetadataCache(key, newData.metaData);
      int? result;
      if (skipCommit) {
        // Purge any previous entry for this key, matching put/remove's
        // skipCommit behaviour. (No-op on a commit-log-free keystore.)
        await _commitLog?.removeEntryFor(hive_key);
        result = -1;
      } else {
        // `_commitLog` is null on a commit-log-free keystore — the write
        // still succeeds, it just produces no sequence number.
        result = await _commitLog?.commit(hive_key, CommitOp.UPDATE_META,
            opTime: assertedTimestamps?.updatedAt);
      }
      _changesController
          .add(existingData == null ? KeyAdded(key) : KeyUpdated(key));
      return result;
    } on HiveError catch (error) {
      logger.severe('HiveAtKeyValueStore get error: $error');
      await _restartHiveBox(error);
      throw DataStoreException(error.message);
    }
  }

  /// Returns true if key exists in [HiveAtKeyValueStore]. false otherwise.
  @override
  Future<bool> exists(String key) async {
    key = key.toLowerCase();
    return getBox().containsKey(HiveKeyStoreHelper.prepareKey(key));
  }

  @override
  Future<int> removeMany(List<String> keys, {bool skipCommit = false}) async {
    if (keys.isEmpty) return 0;
    if (!getBox().isOpen) {
      throw DataStoreException(
          'Failed to bulk-delete. Hive Keystore is not initialized or opened');
    }
    final box = getBox();

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

      // 4. Per-key cache + commit-log bookkeeping. The commit-log
      //    steps are no-ops on a commit-log-free keystore. Commit-log
      //    calls take the prepared (utf7-encoded) form, as in remove().
      final commitLog = _commitLog;
      for (final lowered in present) {
        _expiryKeysCache.remove(lowered);
        if (commitLog == null) continue;
        final hiveKey = HiveKeyStoreHelper.prepareKey(lowered);
        if (skipCommit) {
          // Match remove(): purge any existing commit entry for this
          // key, otherwise sync may consider it valid post-delete.
          await commitLog.removeEntryFor(hiveKey);
        } else {
          await commitLog.commit(hiveKey, CommitOp.DELETE);
        }
      }
    } on Exception catch (exception) {
      logger.severe('HiveAtKeyValueStore removeMany exception: $exception');
      throw DataStoreException(
          'exception in removeMany: ${exception.toString()}');
    } on HiveError catch (error) {
      await _restartHiveBox(error);
      logger.severe('HiveAtKeyValueStore removeMany error: $error');
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
  Future<Map<String, AtData>> getMany(List<String> keys) async {
    if (!getBox().isOpen) {
      throw DataStoreException(
          'Failed to bulk-fetch keys. Hive Keystore is not initialized or opened');
    }
    final box = getBox() as LazyBox;
    final result = <String, AtData>{};
    for (final raw in keys) {
      final lowered = raw.toLowerCase();
      final hiveKey = HiveKeyStoreHelper.prepareKey(lowered);
      if (!box.containsKey(hiveKey)) continue;
      try {
        // A present key always maps to a non-null AtData — the store
        // never persists null. The guard only satisfies the type.
        final value = await box.get(hiveKey);
        if (value != null) {
          value.key = hiveKey;
          result[lowered] = value;
        }
      } on Exception catch (e) {
        logger.severe('HiveAtKeyValueStore getMany exception for "$raw": $e');
        throw DataStoreException('exception in getMany: ${e.toString()}');
      } on HiveError catch (error) {
        logger.severe('HiveAtKeyValueStore getMany error: $error');
        await _restartHiveBox(error);
        throw DataStoreException(error.message);
      }
    }
    return result;
  }

  @override
  Future<Stream<String>> scanKeys(
    KeyPattern pattern, {
    bool includeExpired = false,
    OrderByKey? orderBy,
    int? limit,
    int? skip,
  }) async {
    if (!getBox().isOpen) {
      throw DataStoreException(
          'Failed to scan keys. Hive Keystore is not initialized or opened');
    }

    if (orderBy == null || orderBy == OrderByKey.byKey) {
      return _scanKeysOrdered(
        pattern,
        includeExpired: includeExpired,
        sortByKey: orderBy == OrderByKey.byKey,
        limit: limit,
        skip: skip,
      );
    } else {
      return _scanKeysOrderedByMetadata(
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
    final box = getBox();
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
    final box = getBox() as LazyBox;
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
    if (e is HiveError && !getBox().isOpen) {
      logger.info('Hive box closed. Restarting the hive box');
      await openBox(AtUtils.getShaForAtSign(atSign));
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
    // that the key has neither an expiresAt nor an availableAt.
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
  /// Keyed on the FINAL stored `expiresAt`/`availableAt` values rather than
  /// on ttl/ttb presence: by the time this runs, the metadata builder has
  /// already derived those fields from ttl/ttb where applicable, and a
  /// caller-asserted `expiresAt`/`availableAt` can be set with no ttl/ttb at
  /// all — a key gated on ttl presence would never be swept and would be
  /// served past its expiry. A key with neither field is active forever and
  /// is removed from the cache (covers ttl/ttb unset AND ttl:0/ttb:0, which
  /// the builder maps to null).
  void _updateMetadataCache(String key, AtMetaData? atMetaData) {
    if (atMetaData == null ||
        (atMetaData.expiresAt == null && atMetaData.availableAt == null)) {
      // To prevent stale expiry state being consulted for this key,
      // remove any existing entry from _expiryKeysCache.
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
    await getBox().clear();
    _expiryKeysCache.clear();
  }
}

/// (key, sortField) pair used by `_scanKeysOrderedByMetadata`.
class _KeyWithSortField {
  final String key;
  final DateTime? sortField;
  _KeyWithSortField(this.key, this.sortField);
}

/// A buffered op recorded against a [_HiveAtKeyValueStoreTxn].
/// Applied to the underlying [HiveAtKeyValueStore] at commit
/// time, in insertion order.
abstract class _BufferedOp {
  Future<void> apply(HiveAtKeyValueStore store);
}

class _BufferedPut implements _BufferedOp {
  final String key;
  final AtData value;
  final AtMetaData? metadata;
  _BufferedPut(this.key, this.value, this.metadata);

  @override
  Future<void> apply(HiveAtKeyValueStore store) async {
    await store.putAll(key, value, metadata);
  }
}

class _BufferedRemove implements _BufferedOp {
  final String key;
  _BufferedRemove(this.key);

  @override
  Future<void> apply(HiveAtKeyValueStore store) async {
    await store.remove(key);
  }
}

class _HiveAtKeyValueStoreTxn
    implements KeyStoreTxn<String, AtData, AtMetaData?> {
  final HiveAtKeyValueStore _store;

  /// Buffered ops keyed by lowercased key. The latest op for a
  /// given key wins (a put-then-remove leaves only the remove,
  /// matching what would happen if these ops were applied in
  /// sequence with no transaction).
  final Map<String, _BufferedOp> _ops = <String, _BufferedOp>{};

  _HiveAtKeyValueStoreTxn(this._store);

  @override
  Future<void> put(String key, AtData value, AtMetaData? metadata) async {
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
    return _store.exists(key);
  }
}

/// Best-effort snapshot for Hive. Hive has no MVCC, so reads
/// through this handle observe live state — there is no real
/// isolation. Documented in the abstract; consumers that require
/// isolation gate on `supportsSnapshots`.
class _HiveBestEffortSnapshot
    implements AtKeyValueStoreSnapshot<String, AtData, AtMetaData?> {
  final HiveAtKeyValueStore _store;
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
  Stream<String> scanKeys(KeyPattern pattern) async* {
    if (_released) {
      throw StateError('Snapshot has been released');
    }
    yield* await _store.scanKeys(pattern);
  }

  @override
  Future<void> release() async {
    _released = true;
  }
}
