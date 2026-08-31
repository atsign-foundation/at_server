import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Manages enrollment data in the secondary server.
///
/// This class provides methods to retrieve and store enrollment data
/// associated with a given enrollment ID. It interacts with the
/// AtKeyValueStore to persist and retrieve enrollment information.
class EnrollmentManager {
  final AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
  final String atSign;

  static int cacheHits = 0;
  static int cacheMisses = 0;
  static int cacheInvalidations = 0;

  final AtSignLogger logger = AtSignLogger('EnrollmentManager');

  /// Keep a cache per enrollment key of both the json Map and the
  /// AtData as stored. We need to cache the AtData because we can only check
  /// the 'isActiveKey' with the AtData, but we also don't want to take the
  /// jsonDecode hit every time we fetch. And we cache the json Map rather than
  /// an EnrollDataStoreValue because the EnrollDataStoreValue is mutable and
  /// we don't want its state changing and thus polluting the cache.
  ///
  /// Cache is used by [getEnrollmentByFullKey]. It is invalidated by calls to
  /// [put] and [remove]
  ///
  /// Context:<p/>
  /// Enrollments are fetched on every new verb command received, and on every
  /// check for a connection's authorization to read or write a particular key.
  /// Modifications to enrollments are infrequent - extremely infrequent in
  /// comparison to the number of times they are fetched.
  final Map<String, (AtData, Map<String, dynamic>)> atDataCache = {};

  /// Creates an instance of [EnrollmentManager].
  ///
  /// The [keyStore] is required to interact with the persistence layer.
  EnrollmentManager(this.keyStore, this.atSign);

  /// Retrieves the enrollment data for a given [enId].
  ///
  /// This method constructs an enrollment key, fetches the corresponding
  /// data from the key store, and returns it as an [EnrollDataStoreValue].
  /// If the key is not found, a [KeyNotFoundException] is thrown.
  ///
  /// If the retrieved enrollment data is no longer active, the status
  /// will be set to `expired`.
  ///
  /// If an enrollment has expired then, while the data is returned to the
  /// caller, we also [remove] the enrollment.
  /// Returns:
  ///   An [EnrollDataStoreValue] containing the enrollment details.
  ///
  /// Throws:
  ///   [KeyNotFoundException] if the enrollment key does not exist or has expired.
  Future<EnrollDataStoreValue> getEnrollmentById(String enId) async {
    return getEnrollmentByFullKey(buildEnrollmentKey(enId));
  }

  /// Constructs the enrollment key based on the provided [enId].
  ///
  /// The key format combines the [enId], a new enrollment key pattern,
  /// and the current AtSign.
  ///
  /// Returns:
  ///   A [String] representing the enrollment key.
  String buildEnrollmentKey(String enId) {
    return '$enId'
        '.${EnrollmentConstants.enrollmentKeyPattern}'
        '.${EnrollmentConstants.enrollManageNamespace}'
        '$atSign';
  }

  /// Stores the enrollment data associated with the given [enId].
  ///
  /// This method constructs an enrollment key and saves the provided [AtData]
  /// to the key store. The skipCommit is set to true, to prevent the enrollment
  /// data being synced to the client(s).
  ///
  /// Parameters:
  ///   - [enId]: The ID associated with the enrollment.
  ///   - [atData]: The [AtData] object to be stored.
  ///   - [assertedTimestamps]: timestamps the store must keep faithfully
  ///     rather than rederive. A read-modify-write of an enrollment record
  ///     asserts the stored `expiresAt` back, or the builder recomputes it
  ///     from the retained ttl and restarts the record's expiry clock at the
  ///     moment of the write.
  Future<void> put(String enId, AtData atData, EnrollmentStatus newStatus,
      {AtAssertedTimestamps? assertedTimestamps}) async {
    String ek = buildEnrollmentKey(enId);

    switch (newStatus) {
      case EnrollmentStatus.approved:
        await movePerEnrollmentData(enId,
            to: EnrollmentConstants.perEnrollmentApproved);
        break;
      case EnrollmentStatus.revoked:
        await movePerEnrollmentData(enId,
            to: EnrollmentConstants.perEnrollmentRevoked);
        break;
      default:
        break;
    }

    await keyStore.put(ek, atData,
        skipCommit: true, assertedTimestamps: assertedTimestamps);

    // invalidate the cache
    cacheInvalidations++;
    atDataCache.remove(ek);
  }

  RegExp reForPerEnrollmentNamespaces =
      RegExp(EnrollmentConstants.regexForPerEnrollmentNamespaces);

  /// Moves everything in `<enId>.[ard].__e` to the required place
  /// Returns list of all the keys which were moved
  ///
  /// Scoped to [enId]: only the per-enrollment keys belonging to that enrollment
  /// are moved. The `regexForPerEnrollmentNamespaces` match exposes the owning
  /// enrollment id via its `EnId` named group; keys whose `EnId` differs from
  /// [enId] are left untouched, so a state change on one enrollment never
  /// disturbs another enrollment's per-enrollment data.
  @visibleForTesting
  Future<List<String>> movePerEnrollmentData(
    String enId, {
    required String to,
  }) async {
    switch (to) {
      case EnrollmentConstants.perEnrollmentRevoked:
      case EnrollmentConstants.perEnrollmentDeleted:
      case EnrollmentConstants.perEnrollmentApproved:
        List<String> moved = [];
        final RegExp perEnrollmentRegex =
            RegExp(EnrollmentConstants.regexForPerEnrollmentNamespaces);
        await for (final String fromKey in await keyStore.getKeys(
            regex: EnrollmentConstants.regexForPerEnrollmentNamespaces)) {
          // Scope the move to this enrollment: skip keys owned by any other enrollment.
          final RegExpMatch? match = perEnrollmentRegex.firstMatch(fromKey);
          if (match == null || match.namedGroup('EnId') != enId) {
            continue;
          }
          final String toKey = fromKey
              .replaceAll(
                  '${EnrollmentConstants.perEnrollmentRevoked}@', '$to@')
              .replaceAll(
                  '${EnrollmentConstants.perEnrollmentDeleted}@', '$to@')
              .replaceAll(
                  '${EnrollmentConstants.perEnrollmentApproved}@', '$to@');
          if (toKey == fromKey) {
            continue;
          }

          AtData data = (await keyStore.get(fromKey))!;
          await keyStore.put(toKey, data, skipCommit: false);
          await keyStore.remove(fromKey);
          moved.add(fromKey);
        }
        return moved;
      default:
        throw ArgumentError('movePerEnrollmentData: Invalid "to": "$to"');
    }
  }

  String keyForPEK(String enId) => '$enId'
      '.${AtConstants.defaultEncryptionPrivateKey}'
      '.${EnrollmentConstants.enrollManageNamespace}'
      '$atSign';

  String keyForSEK(String enId) => '$enId'
      '.${AtConstants.defaultSelfEncryptionKey}'
      '.${EnrollmentConstants.enrollManageNamespace}'
      '$atSign';

  /// ```
  /// public:${enVal.appName}.${enVal.deviceName}
  ///   .pkam.${EnrollmentConstants.pkamNamespace}
  ///   .__public_keys$currentAtSign
  /// ```
  String keyForLegacyPK(EnrollDataStoreValue enVal) => 'public:'
      '${enVal.appName}.${enVal.deviceName}'
      '.pkam.${EnrollmentConstants.pkamNamespace}'
      '.__public_keys$atSign';

  final RegExp ekRegex = RegExp(EnrollmentConstants.regexForEnrollmentKey);

  /// Called before *any* key in the keystore is removed.
  /// Checks if what's being removed is an enrollment and, if so,
  /// moves all per-enrollment data to [perEnrollmentDeleted]
  Future preRemoveHook(String key, {required bool skipCommit}) async {
    if (ekRegex.hasMatch(key)) {
      await _preRemove(ek: key);
    }
  }

  Future<void> _preRemove({
    required String ek,
  }) async {
    if (!await keyStore.exists(ek)) {
      logger.info('_preRemove: $ek no longer exists, nothing to do');
      return;
    }

    logger.info('_preRemove($ek)');

    String enId = getIdFromKey(ek);

    // Delete private encryption key if it's there
    final pekKey = keyForPEK(enId);
    if (await keyStore.exists(pekKey)) {
      logger.info('_preRemove: Removing $pekKey');
      await keyStore.remove(pekKey, skipCommit: true);
    } else {
      logger.info('_preRemove: $pekKey has already been removed');
    }

    // Delete self encryption key if it's there
    final sekKey = keyForSEK(enId);
    if (await keyStore.exists(sekKey)) {
      logger.info('_preRemove: Removing $sekKey');
      await keyStore.remove(sekKey, skipCommit: true);
    } else {
      logger.info('_preRemove: $sekKey has already been removed');
    }

    await movePerEnrollmentData(enId,
        to: EnrollmentConstants.perEnrollmentDeleted);
  }

  /// Deletes the enrollment key from the keystore.
  ///
  /// This method generates an enrollment key using the provided enrollmentId and
  /// removes the enrollment key from the keystore. The skipCommit parameter is
  /// set to true to prevent this deletion from being logged in the commit log,
  /// ensuring it is not synced to the clients.
  ///
  /// Parameters:
  ///  - [enId]: The ID associated with the enrollment.
  Future<void> remove({required String enId}) async {
    if (!keyStore.preRemoveHooks.contains(preRemoveHook)) {
      throw StateError('Managing datastore consistency for enrollments requires'
          ' that the preRemoveHook be active');
    }
    String ek = buildEnrollmentKey(enId);

    await keyStore.remove(ek, skipCommit: true);

    // invalidate the cache
    cacheInvalidations++;
    atDataCache.remove(ek);
  }

  Future<List<String>> getAllEnrollmentKeys() async {
    return (await keyStore.getKeys(regex: EnrollmentConstants.enrollmentsRegex))
        .toList();
  }

  /// Fetch an enrollment key from the keystore.
  /// If key is available returns [EnrollDataStoreValue],
  /// else throws [KeyNotFoundException]
  Future<EnrollDataStoreValue> getEnrollmentByFullKey(
    String ek,
  ) async {
    AtData enrollData;
    Map<String, dynamic> enrollJson;

    // Check the cache
    if (atDataCache.containsKey(ek)) {
      // it's in the cache
      cacheHits++;
      (enrollData, enrollJson) = atDataCache[ek]!;
    } else {
      // not in cache - fetch from keystore, and populate the cache
      cacheMisses++;
      enrollData = (await keyStore.get(ek))!;
      enrollJson = jsonDecode(enrollData.data!);
      atDataCache[ek] = (enrollData, enrollJson);
    }

    EnrollDataStoreValue value = EnrollDataStoreValue.fromJson(enrollJson);
    if (!SecondaryUtil.isActiveKey(enrollData)) {
      // When an expired enrollment is encountered, delete it immediately
      logger.warning('getEnrollmentByFullKey:'
          ' Enrollment $ek has expired - removing it');
      await remove(enId: getIdFromKey(ek));

      value.approval = EnrollApproval(EnrollmentStatus.expired.name);
    }
    return value;
  }

  /// Fetch enrollments whose keys are in the [ekList], and filter them to
  /// enrollments whose status is in the [statuses] list.
  ///
  /// When [ekList] is null, fetch and filter all enrollments.
  /// When [statuses] is null, do not filter by status.
  Future<Map<String, Map<String, dynamic>>> getEnrollmentsAsJson(
      {List<String>? ekList, List<EnrollmentStatus>? statuses}) async {
    // set default values for optional arguments - all enrollments, all statuses
    ekList ??= await getAllEnrollmentKeys();

    Map<String, Map<String, dynamic>> ejList = {};
    for (var ek in ekList) {
      EnrollDataStoreValue enVal = await getEnrollmentByFullKey(ek);
      if (statuses == null ||
          statuses.contains(
              EnrollmentStatus.values.byName(enVal.approval!.state))) {
        ejList[ek] = enVal.toJsonExtended();
      }
    }
    return ejList;
  }

  /// Returns all approved enrollments that have access to [namespace], as a
  /// flat list of maps suitable for JSON encoding in the `enroll:listns`
  /// response (1:1:1 — one entry per enrollment, no nested `apkam[]`). Each
  /// entry has shape:
  ///
  /// ```
  /// {"enrollmentId": id, "access": "r"|"rw", "apkamPubKey": pubKey,
  ///  "metadata": map|null}
  /// ```
  ///
  /// `metadata.keyPackage` (a singular, APKAM-signed key package) is the
  /// substrate's encapsulation target; the server stores/returns `metadata`
  /// opaquely.
  ///
  /// The namespace match mirrors the atServer's own suffix rule:
  ///   - `*` authorises every namespace
  ///   - an exact match (e.g. `wavi` authorises `wavi`)
  ///   - a namespace suffix match (e.g. `wavi` authorises `data.wavi`)
  Future<List<Map<String, dynamic>>> getEnrollmentsForNamespace(
      String namespace) async {
    final result = <Map<String, dynamic>>[];
    for (final ek in await getAllEnrollmentKeys()) {
      final EnrollDataStoreValue enVal = await getEnrollmentByFullKey(ek);
      if (enVal.approval?.state != EnrollmentStatus.approved.name) continue;

      String? access;
      for (final entry in enVal.namespaces.entries) {
        final ns = entry.key;
        if (ns == '*' || ns == namespace || namespace.endsWith('.$ns')) {
          access = entry.value;
          break;
        }
      }
      if (access == null) continue;

      result.add({
        'enrollmentId': getIdFromKey(ek),
        'access': access,
        'apkamPubKey': enVal.apkamPublicKey,
        'metadata': enVal.metadata,
      });
    }
    return result;
  }

  /// iterate all enrollments, remove key which leaks appName and deviceName
  Future<List<String>> removeLegacyApkamPublicKeys() async {
    final List<String> deletedLegacyKeys = [];
    final eks = await getAllEnrollmentKeys();
    for (final ek in eks) {
      final EnrollDataStoreValue ev = await getEnrollmentByFullKey(ek);
      final lk = keyForLegacyPK(ev);
      if (await keyStore.exists(lk)) {
        logger.warning('removeLegacyApkamPublicKeys: DELETING $lk');
        await keyStore.remove(lk, skipCommit: true);
        deletedLegacyKeys.add(ek);
      }
    }
    return deletedLegacyKeys;
  }

  /// Called upon server startup. Removes encryption keys of enrollments which
  /// no longer exist (expired or otherwise). Previously these encryption keys
  /// were stored without a ttl even if there was a valid ttl, therefore they
  /// would never be harvested.
  Future<List<String>> removeOrphanedApkamEncryptionKeys() async {
    final List<String> deletedOrphanedKeys = [];
    final List<String> enIds = [];
    for (final ek in await getAllEnrollmentKeys()) {
      enIds.add(getIdFromKey(ek));
    }
    final List<String> candidates = [];
    candidates.addAll(
        await (await keyStore.getKeys(regex: EnrollmentConstants.regexForPEK))
            .toList());
    candidates.addAll(
        await (await keyStore.getKeys(regex: EnrollmentConstants.regexForSEK))
            .toList());
    for (final candidateKey in candidates) {
      String candidateId = getIdFromKey(candidateKey);
      if (!enIds.contains(candidateId)) {
        logger.info('DELETING orphaned key $candidateKey');
        deletedOrphanedKeys.add(candidateKey);
        await keyStore.remove(candidateKey, skipCommit: true);
      } else {
        logger.info('NOT deleting $candidateKey - not orphaned');
      }
    }
    return deletedOrphanedKeys;
  }

  /// Get the enrollmentId from any key where enrollmentId is the first part
  String getIdFromKey(String ek) => ek.substring(0, ek.indexOf('.'));

  /// Caps [enrollmentId] to expire `min(now + grace, its own expiry)` from
  /// this moment, leaving the record in place.
  ///
  /// Re-applied on EVERY retrofit of the same predecessor, computed fresh from
  /// the record's own posture rather than folded into a previously written
  /// cap: sibling clones of one keyfile retrofit whenever each device next
  /// runs, so the cap must RE-ARM with each successor — a deadline fixed by
  /// the first sibling's upgrade would strand every laggard whose next run
  /// falls outside that first window. "Its own expiry" is re-derived from
  /// [EnrollDataStoreValue.apkamKeysExpiryDuration], anchored at the record's
  /// creation, so a key-expiry posture shorter than the grace still wins.
  ///
  /// A written ttl anchors at the write (`expiresAt = now + ttl` in the
  /// metadata builder), so the grace is written as-is — offsetting it by the
  /// record's age would extend the cap by the enrollment's whole lifetime.
  Future<void> capEnrollmentExpiry(
      String enrollmentId, EnrollDataStoreValue enrollment) async {
    final key = buildEnrollmentKey(enrollmentId);
    final AtData? atData;
    try {
      atData = await keyStore.get(key);
    } on KeyNotFoundException {
      return;
    }
    if (atData == null) return;
    final now = DateTime.now().toUtc();
    int cappedTtl =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;
    final ownMs = enrollment.apkamKeysExpiryDuration.inMilliseconds;
    if (ownMs > 0) {
      final createdAt = (atData.metaData?.createdAt ?? now).toUtc();
      final ownRemainingMs = createdAt
          .add(Duration(milliseconds: ownMs))
          .difference(now)
          .inMilliseconds;
      if (ownRemainingMs < cappedTtl) cappedTtl = ownRemainingMs;
    }
    // A ttl of zero means "never expires", and a spent posture must not
    // become immortality — floor at one millisecond.
    if (cappedTtl < 1) cappedTtl = 1;
    atData.metaData = (atData.metaData ?? AtMetaData())..ttl = cappedTtl;
    await put(enrollmentId, atData, EnrollmentStatus.approved);
  }

  /// Arms the retrofit cap on the enrollment [successorEnrollmentId] replaced,
  /// on that successor's FIRST authentication and never again.
  ///
  /// A no-op for an enrollment that replaced nothing, which is every
  /// enrollment except a retrofit's successor.
  ///
  /// Armed here rather than where the successor is stored because storing it
  /// proves only that the SERVER wrote a record. The successor's APKAM private
  /// half is persisted client-side, so a keyfile write that fails, a read-only
  /// file, or a process that dies before the flush each leave the successor
  /// existing on the server and nowhere else — with a clock already started on
  /// the predecessor, which is by then the only credential that still works.
  /// An authentication on a connection the successor opened is what proves the
  /// private half survived and is usable.
  ///
  /// Only the FIRST authentication of any one successor arms. Without that,
  /// every reconnect would rewrite a full grace period onto the predecessor
  /// and it would never retire at all.
  ///
  /// Never throws. This runs after an authentication has already succeeded, and
  /// a predecessor that outlives its window is a slower migration, while an
  /// authentication refused because bookkeeping failed is an outage.
  Future<void> armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
    try {
      // The early exits go through the cached read, because this runs on EVERY
      // APKAM authentication and all but a retrofit's successor leave here.
      // The PKAM path has just read this same enrollment to verify it is
      // active, so the entry is warm.
      final EnrollDataStoreValue cached =
          await getEnrollmentById(successorEnrollmentId);
      final predecessorId = cached.parentEnrollmentId;
      if (predecessorId == null) return;
      if (cached.predecessorCapArmedAt != null) return;

      // Past the exits, and about to write: re-read the stored AtData, which
      // carries the metadata the write has to preserve.
      final key = buildEnrollmentKey(successorEnrollmentId);
      final AtData? atData = await keyStore.get(key);
      final String? raw = atData?.data;
      if (atData == null || raw == null) return;
      final successor = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      if (successor.predecessorCapArmedAt != null) return;

      EnrollDataStoreValue? predecessor;
      try {
        predecessor = await getEnrollmentById(predecessorId);
      } on KeyNotFoundException {
        logger.info('Enrollment $successorEnrollmentId replaced '
            '$predecessorId, which is already gone — nothing to cap');
      }
      if (predecessor != null) {
        await capEnrollmentExpiry(predecessorId, predecessor);
      }

      // Stamped even when the predecessor was already gone, so a retired
      // predecessor does not make every later connection re-walk this.
      successor.predecessorCapArmedAt = DateTime.now().toUtc();
      atData.data = jsonEncode(successor.toJson());
      // The successor's OWN expiry must not move. A plain write re-derives
      // `expiresAt` from the retained ttl and would restart its clock at this
      // moment, silently extending the credential by however long it waited to
      // authenticate; carrying the stored absolute forward as an assertion
      // suppresses that derivation. A null `expiresAt` is a record that never
      // expires, and asserting nothing leaves it that way.
      final storedExpiry = atData.metaData?.expiresAt;
      await put(successorEnrollmentId, atData, EnrollmentStatus.approved,
          assertedTimestamps: storedExpiry == null
              ? null
              : AtAssertedTimestamps(expiresAt: storedExpiry));
    } catch (e) {
      logger.warning('Could not arm the retrofit cap for '
          '$successorEnrollmentId: $e');
    }
  }
}
