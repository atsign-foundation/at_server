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

  /// The ttl a retrofit cap would write onto a record right now:
  /// `min(grace, what the enrollment's own key-expiry posture leaves it)`.
  ///
  /// The posture's deadline is the LATER of `createdAt + posture` and the
  /// record's stored `expiresAt`, and neither alone is right.
  ///
  /// `createdAt + posture` is short by the whole approval latency:
  /// `enroll:approve` starts the posture's clock at APPROVAL, writing
  /// `expiresAt = approvedAt + posture`, while `createdAt` stays at the moment
  /// the request was made. For a record retrofitted between the two it goes
  /// negative, and the floor below turns that into a 1ms cap — a predecessor
  /// with hours of legitimate life killed instantly, and every sibling clone
  /// still to upgrade locked out of the migration.
  ///
  /// `expiresAt` alone is worse in the other direction: after a first sibling
  /// caps the predecessor, `expiresAt` IS that cap, so folding against it
  /// would make every later re-arm shrink rather than extend, and the laggard
  /// the re-arm exists for could never be reached.
  ///
  /// Taking the later of the two is safe because a cap only ever shortens:
  /// both candidates are therefore at or below `approvedAt + posture`, so the
  /// result never grants more life than the posture allows.
  ///
  /// A ttl of zero is the keystore's "never expires", and a spent record must
  /// not become immortal, so the result is floored at one millisecond.
  @visibleForTesting
  int retrofitCapTtlMillis(AtMetaData? recordMetaData,
      EnrollDataStoreValue enrollment, DateTime now) {
    int cappedTtl =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;
    final ownMs = enrollment.apkamKeysExpiryDuration.inMilliseconds;
    final stored = recordMetaData?.expiresAt?.toUtc();
    // A record with no stored expiry never expires, whatever posture its VALUE
    // carries. The CRAM path writes exactly that — the root record is written
    // with no metadata at all while its value may state a posture — so folding
    // against a posture the record never had would compute a deadline in the
    // past for any root older than its stated posture, and the floor below
    // would turn that into a 1ms cap: the root dead instantly and every
    // sibling clone locked out of the migration.
    if (ownMs > 0 && stored != null) {
      final fromCreation = (recordMetaData?.createdAt ?? now)
          .toUtc()
          .add(Duration(milliseconds: ownMs));
      final postureDeadline =
          stored.isAfter(fromCreation) ? stored : fromCreation;
      final remainingMs = postureDeadline.difference(now).inMilliseconds;
      if (remainingMs < cappedTtl) cappedTtl = remainingMs;
    }
    return cappedTtl < 1 ? 1 : cappedTtl;
  }

  /// Whether any enrollment outside [excluding] would still hold FULL
  /// PRIVILEGE — `rw` on both `*` and `__manage` — once [deadline] has passed.
  ///
  /// The precise question behind sparing a predecessor, and behind refusing a
  /// self-revocation: not "is this the atSign's first enrollment", nor "does
  /// the successor outlive it", but whether the act about to be performed
  /// would leave nobody able to restore a root. A candidate that dies before
  /// [deadline] does not count — which is exactly the case that would
  /// otherwise strand the atSign.
  ///
  /// Full privilege rather than the ability to approve, because approving is
  /// checked per namespace against what the approver itself holds: an
  /// enrollment with `__manage` but not `*` can admit new enrollments and can
  /// never admit one carrying `*`, so it keeps an atSign running without being
  /// able to give it a root back.
  ///
  /// [excluding] is a SET rather than a single id because a revoke CASCADES.
  /// The enrollments a cascade is about to revoke are still `approved` in the
  /// keystore while this runs, so asking the question without them would count
  /// the very enrollments the act is about to remove — and report the atSign
  /// safe at the moment it is being stranded.
  Future<bool> hasRootEnrollmentAliveAfter(
      Set<String> excluding, DateTime deadline) async {
    final excludedKeys = excluding.map(buildEnrollmentKey).toSet();
    for (final ek in await getAllEnrollmentKeys()) {
      if (excludedKeys.contains(ek)) continue;
      final EnrollDataStoreValue other;
      try {
        other = await getEnrollmentByFullKey(ek);
      } on KeyNotFoundException {
        continue;
      }
      if (other.approval?.state != EnrollmentStatus.approved.name) continue;
      if (!other.isRootEnrollment) continue;
      final AtData? record = await keyStore.get(ek);
      final expiresAt = record?.metaData?.expiresAt;
      if (expiresAt == null || expiresAt.isAfter(deadline)) return true;
    }
    return false;
  }

  /// Every enrollment reachable from [enrollmentId] by following
  /// predecessor→successor links, to any depth. Never contains [enrollmentId].
  ///
  /// Depth costs nothing to choose. `parentEnrollmentId` has no index, so the
  /// only enumeration available is a pass over every enrollment key with a
  /// decode per key — and that pass builds the WHOLE map, after which the
  /// transitive walk is in memory over a map already held. One level and
  /// arbitrary depth are the same scan; only re-scanning per level would be
  /// slower, which this avoids by construction.
  ///
  /// Enrollments of every status are linked into the map, not just approved
  /// ones. A revoked enrollment part-way down a chain must not hide the
  /// approved enrollment behind it, which is exactly the orphan a cascade
  /// exists to remove.
  Future<Set<String>> descendantsOf(String enrollmentId) async {
    final Map<String, List<String>> successorsOf = {};
    for (final ek in await getAllEnrollmentKeys()) {
      final EnrollDataStoreValue value;
      try {
        value = await getEnrollmentByFullKey(ek);
      } on KeyNotFoundException {
        continue;
      }
      final predecessorId = value.parentEnrollmentId;
      if (predecessorId == null) continue;
      (successorsOf[predecessorId] ??= <String>[]).add(getIdFromKey(ek));
    }

    final Set<String> found = {};
    final List<String> pending = [enrollmentId];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      for (final successor in successorsOf[id] ?? const <String>[]) {
        // `found` is what terminates the walk. The enroll verb cannot build a
        // cycle — a successor is minted with a fresh id and takes the
        // authenticating connection's as its predecessor — but a walk over
        // stored data should not have to rely on that to terminate.
        if (successor == enrollmentId || !found.add(successor)) continue;
        pending.add(successor);
      }
    }
    return found;
  }

  /// Revokes each of [enrollmentIds] that is currently approved, and returns
  /// the ids it actually revoked.
  ///
  /// Anything not currently approved is skipped rather than rewritten: a
  /// denied or already-revoked enrollment is not made "more revoked" by
  /// writing it again, and a pending one is deliberately left alone. A pending
  /// successor of a revoked predecessor is stopped at `enroll:approve`
  /// instead, because it has no credential to strip until it is approved.
  ///
  /// Each write asserts the stored expiry back. A revoke says nothing about
  /// expiry, and the metadata builder re-derives `expiresAt = now + ttl` from
  /// the retained ttl on any write that does not assert it — so a cascade
  /// would otherwise hand every enrollment it revoked a fresh full lifetime,
  /// and restart any retrofit cap standing on those records.
  Future<List<String>> revokeAll(Iterable<String> enrollmentIds) async {
    final List<String> revoked = [];
    for (final id in enrollmentIds) {
      final ek = buildEnrollmentKey(id);
      final AtData? atData = await keyStore.get(ek);
      final String? raw = atData?.data;
      if (atData == null || raw == null) continue;
      final EnrollDataStoreValue value;
      try {
        value = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      } catch (e) {
        logger.severe('Cascade could not decode enrollment $id: $e');
        continue;
      }
      if (value.approval?.state != EnrollmentStatus.approved.name) continue;
      value.approval!.state = EnrollmentStatus.revoked.name;
      // Stamped here as well as on the named target: an enrollment swept up by
      // a cascade is as revoked as one an operator named, and a reader must
      // not have to know which happened to learn when it stopped being usable.
      value.revokedAt = DateTime.now().toUtc();
      atData.data = jsonEncode(value.toJson());
      final storedExpiry = atData.metaData?.expiresAt;
      await put(id, atData, EnrollmentStatus.revoked,
          assertedTimestamps: storedExpiry == null
              ? null
              : AtAssertedTimestamps(expiresAt: storedExpiry));
      revoked.add(id);
    }
    return revoked;
  }

  /// Caps [enrollmentId] to expire [retrofitCapTtlMillis] from this moment,
  /// leaving the record in place.
  ///
  /// Re-applied every time a successor ARMS — which is its first
  /// authentication, not its enrolment; a successor that never authenticates
  /// caps nothing. Computed fresh from the predecessor's own posture rather
  /// than folded into a previously written cap: sibling clones of one keyfile
  /// upgrade whenever each device next runs, so the cap must RE-ARM with each
  /// successor, and a deadline fixed by the first sibling's upgrade would
  /// strand every laggard whose next run falls outside that first window.
  ///
  /// A written ttl anchors at the write (`expiresAt = now + ttl` in the
  /// metadata builder), so the ttl is written as-is — offsetting it by the
  /// record's age would extend the cap by the enrollment's whole lifetime.
  ///
  /// [ttlMillis] is the value a caller has already computed and made a
  /// decision on. Recomputing it here would write a deadline LATER than the
  /// one that was checked, by however long the checking took — the unsafe
  /// direction, since the check is what established that somebody survives it.
  Future<void> capEnrollmentExpiry(
      String enrollmentId, EnrollDataStoreValue enrollment,
      {int? ttlMillis}) async {
    final key = buildEnrollmentKey(enrollmentId);
    final AtData? atData;
    try {
      atData = await keyStore.get(key);
    } on KeyNotFoundException {
      return;
    }
    if (atData == null) return;
    atData.metaData = (atData.metaData ?? AtMetaData())
      ..ttl = ttlMillis ??
          retrofitCapTtlMillis(
              atData.metaData, enrollment, DateTime.now().toUtc());
    // The status this write carries is the one the record already has: `put`
    // moves the enrollment's per-enrollment data to match, and capping must
    // not relocate anything. A revoked predecessor is not capped at all (see
    // [armRetrofitCapOnFirstAuth]), but passing its own status keeps that
    // true of any future caller.
    await put(enrollmentId, atData,
        EnrollmentStatus.values.byName(enrollment.approval!.state));
  }

  /// Arms the retrofit cap on the enrollment [successorEnrollmentId] replaced,
  /// once, at the first authentication where the conditions below permit it.
  ///
  /// Usually that is the successor's very first authentication. When a
  /// condition declines, nothing is recorded and the question is asked again
  /// next time, so the arming authentication may be a later one.
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
  /// TWO CONDITIONS STOP THE CAP, and neither stamps the successor: both are
  /// judgements about state that can change, so they are re-made on the next
  /// authentication rather than frozen into the record.
  ///
  /// * **A predecessor that is not approved.** It is already retired, and
  ///   writing it back would hand it a fresh ttl it has no business carrying.
  ///   An unrevoke restores an ordinary predecessor, so this must not become
  ///   permanent.
  /// * **A successor that would die before the deadline, when the predecessor
  ///   is the atSign's LAST holder of `__manage`.** Capping the only
  ///   enrollment that can approve another, in favour of one that will be gone
  ///   first, leaves nobody able to admit a replacement. Every other
  ///   predecessor is capped regardless of the successor's lifetime: declining
  ///   more widely than this would silently switch retirement off for any
  ///   fleet whose APKAM keys are shorter-lived than the grace, and would make
  ///   the grace knob work backwards — a longer grace declining more often.
  ///
  /// Never throws. This runs after an authentication has already succeeded, and
  /// a predecessor that outlives its window is a slower migration, while an
  /// authentication refused because bookkeeping failed is an outage.
  Future<void> armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
    try {
      // The early exit goes through the cached read, because this runs on
      // EVERY APKAM authentication and all but a retrofit's successor leave
      // here. The PKAM path has just read this same enrollment, so it is warm.
      final EnrollDataStoreValue cached =
          await getEnrollmentById(successorEnrollmentId);
      final predecessorId = cached.parentEnrollmentId;
      if (predecessorId == null) return;
      if (cached.predecessorCapArmedAt != null) return;

      final key = buildEnrollmentKey(successorEnrollmentId);

      EnrollDataStoreValue? predecessor;
      try {
        predecessor = await getEnrollmentById(predecessorId);
      } on KeyNotFoundException {
        logger.info('Enrollment $successorEnrollmentId replaced '
            '$predecessorId, which is already gone — nothing to cap');
      }

      bool armPredecessor = false;
      int? capTtlMillis;
      final bool predecessorGone = predecessor == null;

      if (predecessor != null) {
        if (predecessor.approval?.state != EnrollmentStatus.approved.name) {
          // Not capped: a predecessor that is denied, revoked or expired is
          // already retired, and writing it back would give it a fresh ttl it
          // has no business carrying. Left unstamped deliberately — an
          // unrevoke restores an ordinary approved predecessor, and a
          // transient state must not become a permanent exemption.
          logger.info(
              'Enrollment $successorEnrollmentId replaced $predecessorId, '
              'which is ${predecessor.approval?.state} — not capping it');
        } else {
          final now = DateTime.now().toUtc();
          final AtData? predecessorRecord =
              await keyStore.get(buildEnrollmentKey(predecessorId));
          capTtlMillis = retrofitCapTtlMillis(
              predecessorRecord?.metaData, predecessor, now);
          final deadline = now.add(Duration(milliseconds: capTtlMillis));

          // Would the successor still be here when the cap fires? If so it IS
          // a live root — it carries the predecessor's grants verbatim — so
          // nothing can be stranded and the walk below is unnecessary. This is
          // the ordinary case and it costs no keystore scan.
          final successorExpiry =
              (await keyStore.get(key))?.metaData?.expiresAt;
          final successorOutlivesCap = successorExpiry == null ||
              !successorExpiry.isBefore(deadline);

          // Spared only when capping would leave the atSign unable to restore
          // itself: the predecessor holds FULL privilege, the successor will
          // be gone by the deadline, and no other fully-privileged enrollment
          // survives it. Full privilege rather than the ability to approve,
          // because approving is checked per namespace against what the
          // approver holds — a `__manage`-only enrollment can admit new
          // enrollments and can never admit one carrying `*`, so it keeps an
          // atSign running without being able to give it a root back.
          //
          // Every other predecessor is capped regardless of its successor's
          // lifetime: declining more widely would switch retirement off for
          // any fleet whose keys are shorter-lived than the grace, and would
          // make the grace setting work backwards.
          if (!successorOutlivesCap &&
              predecessor.isRootEnrollment &&
              !await hasRootEnrollmentAliveAfter({predecessorId}, deadline)) {
            logger.warning(
                'Not capping $predecessorId at $deadline on the word of '
                '$successorEnrollmentId, which expires at $successorExpiry: '
                '$predecessorId holds full privilege and no other '
                'fully-privileged enrollment would still be alive then. The '
                'atSign would be left unable to restore a root');
          } else {
            armPredecessor = true;
          }
        }
      }

      // Recorded only when the cap is going to fire, or when the predecessor
      // is permanently gone. A decline is a judgement about state that can
      // change — an unrevoke, a longer-lived sibling — so it must be re-made
      // on the next authentication rather than frozen here.
      if (!armPredecessor && !predecessorGone) return;

      // Re-read immediately before the write, NARROWING a lost update rather
      // than closing it. Everything above awaits — the predecessor lookup, and
      // a cap that walks the whole keystore — so a snapshot taken before all
      // that would very likely revert a concurrent `enroll:update` key
      // rotation or an `enroll:revoke` of this successor. A window remains:
      // `put` itself walks the keystore before writing, and the keystore has
      // no compare-and-set, so this is read-modify-write on shared durable
      // state and the guarantee is probabilistic.
      final AtData? atData = await keyStore.get(key);
      final String? raw = atData?.data;
      if (atData == null || raw == null) return;
      final successor = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      // Load-bearing, not belt-and-braces: `put` invalidates the cache only
      // after its own await, so a concurrent reader can repopulate it with a
      // pre-write value. This uncached re-test is what actually makes "first"
      // hold; the cached check above is only the fast path.
      if (successor.predecessorCapArmedAt != null) return;

      successor.predecessorCapArmedAt = DateTime.now().toUtc();
      atData.data = jsonEncode(successor.toJson());
      // The successor's OWN expiry must not move. A plain write re-derives
      // `expiresAt` from the retained ttl and would restart its clock at this
      // moment, silently extending the credential by however long it waited to
      // authenticate; carrying the stored absolute forward as an assertion
      // suppresses that derivation. A null `expiresAt` is a record that never
      // expires, and asserting nothing leaves it that way.
      final storedExpiry = atData.metaData?.expiresAt;
      // The record's OWN status, never a default. `put` moves an enrollment's
      // per-enrollment data to match the status it is handed, so defaulting to
      // `approved` here would relocate the data of a record whose state we
      // could not read — the same relocation `capEnrollmentExpiry` passes the
      // record's own status to avoid. An unparseable status cannot reach a
      // successful PKAM (the handler resolves the same enum on the way in), so
      // this is unreachable; if it ever fires, refusing to write is the only
      // safe move.
      final EnrollmentStatus? successorStatus =
          EnrollmentStatus.values.asNameMap()[successor.approval?.state ?? ''];
      if (successorStatus == null) {
        logger.severe(
            'Enrollment $successorEnrollmentId has an unreadable approval '
            'state ${successor.approval?.state}; not stamping it');
        return;
      }
      await put(successorEnrollmentId, atData, successorStatus,
          assertedTimestamps: storedExpiry == null
              ? null
              : AtAssertedTimestamps(expiresAt: storedExpiry));

      // The cap goes LAST, after the stamp. If a write fails between the two,
      // the successor is recorded as processed and the predecessor simply
      // keeps the expiry it already had — the migration is slower and nothing
      // else moves. The other order fails far worse: a capped predecessor with
      // no stamp is re-capped on every later authentication, each time with a
      // fresh full grace, so it never retires at all.
      if (armPredecessor && predecessor != null) {
        await capEnrollmentExpiry(predecessorId, predecessor,
            ttlMillis: capTtlMillis);
      }
    } catch (e) {
      logger.warning('Could not arm the retrofit cap for '
          '$successorEnrollmentId: $e');
    }
  }
}
