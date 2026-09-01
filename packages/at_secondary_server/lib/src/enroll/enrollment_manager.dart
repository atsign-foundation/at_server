import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_revocation_event.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

/// Manages enrollment data in the secondary server.
///
/// This class provides methods to retrieve and store enrollment data
/// associated with a given enrollment ID. It interacts with the
/// AtKeyValueStore to persist and retrieve enrollment information.
/// What [EnrollmentManager.capEnrollmentExpiry] did, which its caller needs in
/// order to decide whether the successor's "I have settled this" stamp is
/// honest. A stamp left standing over a cap that did not happen is permanent:
/// it short-circuits every later authentication, so the predecessor would keep
/// an uncapped credential forever.
enum RetrofitCapOutcome {
  /// The expiry was written.
  capped,

  /// The predecessor's record is gone. Nothing to cap and nothing can bring
  /// it back, so the successor's stamp stands.
  predecessorGone,

  /// The predecessor was approved when the decision was made and is not now.
  /// Transient by nature — an un-revoke restores it — so the stamp must NOT
  /// stand.
  notApproved,

  /// The record could not be read or decoded. Treated like [notApproved]: it
  /// says nothing durable about the predecessor.
  unreadable,
}

class EnrollmentManager {
  final AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
  final String atSign;

  static int cacheHits = 0;
  static int cacheMisses = 0;
  static int cacheInvalidations = 0;

  /// Successors whose cap was DECLINED, against the cache generation at which
  /// the decision was taken.
  ///
  /// A decline deliberately leaves no durable stamp, because it is a judgement
  /// about state that can change. Without this the expensive half of that
  /// judgement — a whole-keystore walk looking for another fully privileged
  /// enrollment — re-ran on every authentication of that successor, forever,
  /// and the answer that repeats is the expensive one: the walk returns early
  /// on the first surviving root, so only the "nobody survives" case pays for
  /// all of it. The triggering posture is ordinary rather than exotic: a
  /// single-root atSign whose root retrofits asking for a shorter key life.
  ///
  /// [cacheInvalidations] is bumped by every enrollment write, so any change
  /// to any enrollment re-opens the question. In-process only: a restart
  /// re-decides, which is correct and costs one walk.
  static final Map<String, int> declinedAtGeneration = {};

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

    await _writeEnrollmentRecord(enId, atData,
        assertedTimestamps: assertedTimestamps);
  }

  /// The record write and cache invalidation, without the per-enrollment data
  /// move. Split out so a caller moving data for MANY enrollments can make one
  /// pass and then write each record, rather than paying a whole-keystore walk
  /// per record. Every write still bumps [cacheInvalidations], which the
  /// retrofit-cap decline memo keys on.
  Future<void> _writeEnrollmentRecord(String enId, AtData atData,
      {AtAssertedTimestamps? assertedTimestamps}) async {
    final String ek = buildEnrollmentKey(enId);
    await keyStore.put(ek, atData,
        skipCommit: true, assertedTimestamps: assertedTimestamps);
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
  }) =>
      movePerEnrollmentDataFor({enId}, to: to);

  /// [movePerEnrollmentData] for several enrollments in ONE pass.
  ///
  /// The pass is the cost: `getKeys` walks every key in the atSign's keystore,
  /// so doing it once per enrollment made a cascade quadratic in the thing an
  /// attacker can inflate — a revoke of K descendants cost K+2 whole-store
  /// scans, and self-enrollment mints descendants without approval. Batching
  /// is sound because the regex already exposes the owning enrollment id, so
  /// one walk can serve any number of them.
  @visibleForTesting
  Future<List<String>> movePerEnrollmentDataFor(
    Set<String> enIds, {
    required String to,
  }) async {
    if (enIds.isEmpty) return [];
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
          if (match == null || !enIds.contains(match.namedGroup('EnId'))) {
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
      EnrollDataStoreValue enVal;
      try {
        enVal = await getEnrollmentByFullKey(ek);
      } on KeyNotFoundException {
        // Deleted between the enumeration and this read. One enrollment
        // vanishing must not fail the whole roster.
        continue;
      }
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
  /// The access [enVal] holds over [namespace], or null if it holds none.
  ///
  /// A `*` grant covers every namespace, and a grant on a parent segment
  /// covers its children — the same rule the verb handler gates the caller on,
  /// so a caller admitted to a roster is always ON that roster.
  String? accessForNamespace(EnrollDataStoreValue enVal, String namespace) =>
      accessInNamespaces(enVal.namespaces, namespace);

  /// [accessForNamespace] over a bare grants map.
  ///
  /// Separate because a revocation event carries the grants the enrollment
  /// held rather than the enrollment, the record having very possibly been
  /// reaped since — so the same rule has to be askable without one.
  String? accessInNamespaces(Map<String, String> namespaces, String namespace) {
    // An EXPLICIT grant wins, and the wildcard is only a fallback — which is
    // the atServer's own rule: it walks the enrolled namespaces for a suffix
    // match and reaches for `*` only when none matched. Testing `*` inside the
    // loop instead returns whichever entry happens to come first in the stored
    // map, and that map is insertion-ordered off `jsonDecode`, so an
    // enrollment holding both `*` and a narrower grant at different access
    // letters would report a letter the server itself would not act on —
    // whenever `*` happened to be stored first.
    for (final entry in namespaces.entries) {
      final ns = entry.key;
      if (ns == EnrollmentConstants.allNamespaces) continue;
      if (ns == namespace || namespace.endsWith('.$ns')) {
        return entry.value;
      }
    }
    return namespaces[EnrollmentConstants.allNamespaces];
  }

  /// The approved enrollments holding [namespace].
  ///
  /// Approved only, which is what makes revocation bind a HOLDER: a revoked
  /// enrollment leaves every roster at once, on every client, including ones
  /// that never heard about the revocation.
  Future<List<Map<String, dynamic>>> getEnrollmentsForNamespace(
      String namespace) async {
    final result = <Map<String, dynamic>>[];
    for (final ek in await getAllEnrollmentKeys()) {
      final EnrollDataStoreValue enVal;
      try {
        enVal = await getEnrollmentByFullKey(ek);
      } on KeyNotFoundException {
        continue; // reaped between the enumeration and this read
      }
      if (enVal.approval?.state != EnrollmentStatus.approved.name) continue;
      final String? access = accessForNamespace(enVal, namespace);
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

  /// The most recent moment any enrollment holding [namespace] was REVOKED, or
  /// null if none has been.
  ///
  /// Deliberately not folded into [getEnrollmentsForNamespace]: this is a fact
  /// about the namespace, not about any member of its roster, and a roster is
  /// a list of members with nowhere to put one. It answers `enroll:infons`,
  /// which exists so that the answer has a shape it fits.
  ///
  /// Revoked enrollments count whatever put them there. A cascade revokes a
  /// successor holding its predecessor's namespaces exactly, so a revocation
  /// reaches this answer through a descendant as readily as through the
  /// enrollment an operator named.
  ///
  /// Derived from the revocation EVENTS rather than from the enrollments,
  /// which is what makes the answer survive. An enrollment record carries the
  /// APKAM key-expiry posture as its ttl, so a revoked enrollment is reaped on
  /// the schedule its credential was issued under; reading the roster would
  /// therefore let this answer go backwards, or vanish, on a timetable chosen
  /// by whoever set that posture.
  ///
  /// An un-revoke WITHDRAWS a revocation here, exactly as clearing the old
  /// per-enrollment stamp did: the counter-event is what the log records, and
  /// this reads the net. So the value can move backwards when an un-revoke
  /// lands — a client comparing it must ask whether it CHANGED, not whether it
  /// grew. The events themselves are never rewritten, so the history an audit
  /// wants is still there; it is only this derived answer that nets out.
  Future<DateTime?> lastRevocationForNamespace(String namespace) async {
    // Per enrollment, not globally: an un-revoke withdraws its own
    // enrollment's revocation and says nothing about anyone else's.
    final Map<String, EnrollmentRevocationEvent> lastRevoke = {};
    final Map<String, DateTime> lastUnrevoke = {};
    for (final event in await revocationEvents()) {
      if (event.type == EnrollmentRevocationEventType.revoked) {
        final prev = lastRevoke[event.enrollmentId];
        if (prev == null || event.at.isAfter(prev.at)) {
          lastRevoke[event.enrollmentId] = event;
        }
      } else {
        final prev = lastUnrevoke[event.enrollmentId];
        if (prev == null || event.at.isAfter(prev)) {
          lastUnrevoke[event.enrollmentId] = event.at;
        }
      }
    }

    DateTime? latest;
    for (final entry in lastRevoke.entries) {
      final DateTime? withdrawn = lastUnrevoke[entry.key];
      // A TIE counts as withdrawn. An un-revoke can only follow a revoke, so
      // two events on one enrollment sharing a millisecond can only be a
      // revocation and the withdrawal of it.
      if (withdrawn != null && !withdrawn.isBefore(entry.value.at)) continue;
      // Matched against the grants the enrollment held AT THE REVOCATION,
      // which is the only surviving record of which namespaces it took with
      // it.
      if (accessInNamespaces(entry.value.namespaces, namespace) == null) {
        continue;
      }
      final DateTime at = entry.value.at;
      if (latest == null || at.isAfter(latest)) latest = at;
    }
    return latest;
  }

  /// The at-rest key pattern for a revocation-history record.
  ///
  /// Deliberately NOT built on [EnrollmentConstants.enrollmentKeyPattern]:
  /// [EnrollmentConstants.enrollmentsRegex] is an UNANCHORED substring, so any
  /// key carrying `.new.enrollments.__manage@` anywhere in it is enumerated by
  /// [getAllEnrollmentKeys] and handed to a decoder expecting an
  /// [EnrollDataStoreValue]. It stays inside `__manage` so that scan hides it
  /// under the rule that already hides enrollment records.
  static const String revocationEventKeyPattern = 'revocation.events';

  static const String revocationEventsRegex =
      '\\.revocation\\.events\\.${EnrollmentConstants.enrollManageNamespace}@';

  String buildRevocationEventKey(String eventId) => '$eventId'
      '.$revocationEventKeyPattern'
      '.${EnrollmentConstants.enrollManageNamespace}'
      '$atSign';

  /// Appends [events] to the revocation history.
  ///
  /// One record each, keyed by a fresh id: the history is append-only, and
  /// nothing here reads or rewrites what is already stored. `skipCommit` for
  /// the same reason enrollment records use it — this is the atServer's own
  /// bookkeeping and has no business in a client's sync stream.
  ///
  /// No ttl. That is the point of the log, and it is also unbounded growth:
  /// one record per revocation, kept for the life of the atSign, and a cascade
  /// writes one per enrollment it takes. Small records — a few hundred bytes —
  /// but nothing prunes them, and no retention policy has been decided.
  Future<void> recordRevocationEvents(
      List<EnrollmentRevocationEvent> events) async {
    for (final EnrollmentRevocationEvent event in events) {
      await keyStore.put(buildRevocationEventKey(Uuid().v4()),
          AtData()..data = jsonEncode(event.toJson()),
          skipCommit: true);
    }
  }

  /// Every revocation event the atSign holds, in no particular order.
  ///
  /// A record that cannot be read is LOGGED AND SKIPPED rather than thrown
  /// past the caller: the alternative is one malformed record making
  /// `enroll:infons` permanently unanswerable, and a skip is visible in the
  /// logs while a thrown decode error stops the verb for every namespace.
  Future<List<EnrollmentRevocationEvent>> revocationEvents() async {
    final List<EnrollmentRevocationEvent> events = [];
    await for (final String key
        in await keyStore.getKeys(regex: revocationEventsRegex)) {
      final AtData? record;
      try {
        record = await keyStore.get(key);
      } on KeyNotFoundException {
        continue; // reaped between the enumeration and this read
      }
      final String? raw = record?.data;
      if (raw == null) continue;
      try {
        events.add(EnrollmentRevocationEvent.fromJson(jsonDecode(raw)));
      } on FormatException catch (e) {
        logger.severe('Revocation event $key does not decode; skipping it: $e');
      } on TypeError catch (e) {
        logger.severe('Revocation event $key has the wrong shape; '
            'skipping it: $e');
      }
    }
    return events;
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

  /// The predecessor [id] records, read straight off the stored record.
  ///
  /// Deliberately NOT via [getEnrollmentByFullKey]: that treats an elapsed ttl
  /// as a reason to DELETE the record, and a link being walked during a
  /// revocation is the worst possible moment to reap it. `keyStore.get`
  /// returns a record whose ttl has elapsed — expiry is a judgement its
  /// callers apply — which is what lets the walk cross an expired link.
  ///
  /// ⚠️ Only until the SWEEP runs. The server schedules a periodic
  /// `deleteExpiredKeys()` pass, so an expired enrollment record is removed
  /// within tens of seconds of expiring and this read then throws like any
  /// other absent key. Crossing an expired link is therefore a window, not a
  /// property. See [descendantsOf].
  Future<String?> _predecessorIdOf(String id, Map<String, String?> memo) async {
    if (memo.containsKey(id)) return memo[id];
    String? predecessorId;
    try {
      final AtData? record = await keyStore.get(buildEnrollmentKey(id));
      final String? raw = record?.data;
      if (raw != null) {
        predecessorId =
            EnrollDataStoreValue.fromJson(jsonDecode(raw)).parentEnrollmentId;
      }
    } on KeyNotFoundException {
      // Genuinely absent: this chain ends here and no other.
      predecessorId = null;
    } on FormatException catch (e) {
      // Present but undecodable. Same outcome, but it is not routine.
      logger.severe('Enrollment $id does not decode; treating it as the end '
          'of the chain it is in: $e');
      predecessorId = null;
    }
    // A STORE fault is deliberately NOT caught. Swallowing it would end the
    // chain silently, drop every enrollment behind this link out of the
    // cascade, and let the verb report success on a partial revocation — and
    // the memo would then serve that answer to every other candidate whose
    // chain runs through this id. Before this walk existed the same fault
    // aborted the revoke and wrote nothing; failing closed keeps that.
    memo[id] = predecessorId;
    return predecessorId;
  }

  /// Every enrollment that reaches [enrollmentId] by following predecessor
  /// links upward, to any depth. Never contains [enrollmentId].
  ///
  /// Walked UPWARD from each candidate rather than downward from the target,
  /// and the difference is load-bearing. A downward walk has to ENUMERATE the
  /// intermediate links to learn their edges, and key enumeration hides
  /// records whose ttl has elapsed — so an expired enrollment part-way down a
  /// retrofit chain took its edge with it and every enrollment behind it
  /// survived the cascade.
  ///
  /// A retrofit is now a ONCE-OFF — `enroll:request` refuses to replace an
  /// enrollment that is itself a replacement — so a chain minted by this
  /// server is one link deep and has no middle for that to happen to. The
  /// upward walk is kept for what it still faces: records written by a server
  /// that predates that guard, which can be arbitrarily deep and whose middle
  /// links expire on whatever posture minted them.
  ///
  /// Upward, only the CANDIDATES need enumerating — and a candidate a cascade
  /// could revoke is by definition a live one — while each link in the chain
  /// is fetched by key, which returns expired records.
  ///
  /// ⚠️ A SEVERED link orphans everything behind it, because nothing records
  /// an enrollment's ancestry beyond its immediate predecessor. Two things
  /// sever one, and the second is not an edge case:
  ///
  /// * `enroll:delete` on a middle link.
  /// * the scheduled expiry sweep. Fetching by key crosses a link whose ttl
  ///   has elapsed, but the server also runs a periodic `deleteExpiredKeys()`
  ///   pass, so that window closes within tens of seconds and the record is
  ///   then gone for good. This reaches a chain of two or more links only —
  ///   which this server no longer mints, but may still be holding from
  ///   before the once-off guard. Each successor's ttl clock restarts at its
  ///   own write, so earlier links expire before later ones and a revoke
  ///   arriving after the sweep reaches the first live candidate and stops.
  ///
  /// Closing that needs ancestry that outlives the record, which this does not
  /// have.
  ///
  /// Every status is followed. A revoked or expired enrollment part-way down a
  /// retrofit chain must not hide the enrollment behind it, which is exactly
  /// the orphan a cascade exists to remove.
  ///
  /// ⚠️ This follows the REPLACEMENT edge only. An enrollment that merely
  /// APPROVED another is not its predecessor and is not walked: no approver
  /// edge is stored on the record at all, so approval depth is unbounded and
  /// invisible here. Revoking an approver does not revoke what it admitted.
  Future<Set<String>> descendantsOf(String enrollmentId) async {
    final Set<String> found = {};
    final Map<String, String?> memo = {};
    for (final ek in await getAllEnrollmentKeys()) {
      final String candidate = getIdFromKey(ek);
      if (candidate == enrollmentId) continue;
      // `seen` terminates the climb. The enroll verb cannot build a cycle — a
      // successor is minted with a fresh id and takes the authenticating
      // connection's as its predecessor — but a walk over stored data should
      // not have to rely on that to terminate.
      final Set<String> seen = {candidate};
      String? current = await _predecessorIdOf(candidate, memo);
      while (current != null && seen.add(current)) {
        if (current == enrollmentId) {
          found.add(candidate);
          break;
        }
        current = await _predecessorIdOf(current, memo);
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
  /// Each write asserts the stored expiry back, and the per-enrollment data
  /// move is made ONCE for the whole set rather than per record.
  ///
  /// [byEnrollmentId] is the enrollment on the connection that issued the
  /// command, null for a CRAM or legacy-PKAM owner; [cascadedFrom] is the
  /// enrollment it NAMED. Both are recorded on every event this writes,
  /// because an enrollment revoked by a cascade was revoked for a reason that
  /// is not visible from its own record.
  ///
  /// [at] is the moment of the COMMAND, passed in rather than taken here so
  /// that the enrollment an operator named and every enrollment the cascade
  /// took carry one timestamp. They are revoked by a single act; stamping each
  /// with the instant its own write happened would invite a reader to order
  /// them against one another as though they were separate decisions, and the
  /// order they would then read is an artefact of the retry-safe write order.
  Future<List<String>> revokeAll(Iterable<String> enrollmentIds,
      {required String? byEnrollmentId,
      required String cascadedFrom,
      required DateTime at}) async {
    final List<String> revoked = [];
    // The grants each one held, captured before the write, because the event
    // outlives the record they are stored on.
    final Map<String, Map<String, String>> grantsHeld = {};
    // Prepared first, written second, so the per-enrollment data move can be
    // made ONCE for the whole cascade. Going through `put` per descendant cost
    // a whole-keystore walk each — K+2 scans for a cascade of K, on a path
    // whose K is inflatable by minting successors, which needs no approval.
    final Map<String, AtData> pending = {};
    for (final id in enrollmentIds) {
      final ek = buildEnrollmentKey(id);
      // `get` THROWS on an absent key rather than returning null, so this is
      // not belt-and-braces: without it a descendant deleted or reaped between
      // the walk and this loop aborts the whole verb, leaving the enrollments
      // already revoked with their connections still open.
      final AtData? atData;
      try {
        atData = await keyStore.get(ek);
      } on KeyNotFoundException {
        logger.info('Cascade: enrollment $id is already gone; skipping');
        continue;
      }
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
      pending[id] = atData;
      grantsHeld[id] = Map<String, String>.from(value.namespaces);
      atData.data = jsonEncode(value.toJson());
      revoked.add(id);
    }
    if (revoked.isEmpty) return revoked;

    // The history goes in BEFORE the records change, and the asymmetry is
    // deliberate: a crash between the two leaves an event describing a
    // revocation that did not land, which moves `lastRevokedAt` early and
    // costs a client a refetch. The other order loses the fact entirely, and
    // an under-stated revocation tells a client nothing changed when
    // something did.
    await recordRevocationEvents([
      for (final String id in revoked)
        EnrollmentRevocationEvent(
          type: EnrollmentRevocationEventType.revoked,
          enrollmentId: id,
          at: at,
          namespaces: grantsHeld[id]!,
          byEnrollmentId: byEnrollmentId,
          cascadedFrom: cascadedFrom,
        )
    ]);

    // One pass for every enrollment the cascade takes, then the records. `put`
    // would repeat the pass per record; the move is the expensive half and it
    // is identical work for all of them.
    await movePerEnrollmentDataFor(revoked.toSet(),
        to: EnrollmentConstants.perEnrollmentRevoked);
    for (final id in revoked) {
      final AtData atData = pending[id]!;
      // The stored expiry is asserted back on each write. A revoke says
      // nothing about expiry, and the metadata builder re-derives
      // `expiresAt = now + ttl` from the retained ttl on any write that does
      // not assert it — so a cascade would otherwise hand every enrollment it
      // revoked a fresh full lifetime, and restart any retrofit cap on them.
      final storedExpiry = atData.metaData?.expiresAt;
      await _writeEnrollmentRecord(id, atData,
          assertedTimestamps: storedExpiry == null
              ? null
              : AtAssertedTimestamps(expiresAt: storedExpiry));
    }
    return revoked;
  }

  /// Takes back a `predecessorCapArmedAt` stamp whose cap did not happen.
  ///
  /// Re-read immediately before the write for the same reason the stamp itself
  /// is: everything in between awaits, and a snapshot from before all of it
  /// would revert a concurrent change to this successor. Best-effort — if it
  /// fails the successor stays stamped, which is the pre-existing behaviour
  /// and no worse than not trying.
  Future<void> _clearCapStamp(String successorEnrollmentId, String key) async {
    try {
      final AtData? atData = await keyStore.get(key);
      final String? raw = atData?.data;
      if (atData == null || raw == null) return;
      final value = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      if (value.predecessorCapArmedAt == null) return;
      final status =
          EnrollmentStatus.values.asNameMap()[value.approval?.state ?? ''];
      if (status == null) return;
      value.predecessorCapArmedAt = null;
      atData.data = jsonEncode(value.toJson());
      final storedExpiry = atData.metaData?.expiresAt;
      await put(successorEnrollmentId, atData, status,
          assertedTimestamps: storedExpiry == null
              ? null
              : AtAssertedTimestamps(expiresAt: storedExpiry));
      logger.info(
          'Took back the retrofit-cap stamp on $successorEnrollmentId: the '
          'cap it recorded did not happen, and the reason was transient');
    } catch (e) {
      logger.warning(
          'Could not take back the retrofit-cap stamp on '
          '$successorEnrollmentId: $e');
    }
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
  /// The ttl is computed HERE, against the record this method just read,
  /// rather than taken from the caller. A ttl is a distance from the instant
  /// it was computed at and the store re-anchors it at the instant of the
  /// write, so a value computed before the caller's keystore walk is stamped
  /// as the deadline it checked PLUS however long that walk took. Recomputing
  /// lands on the checked deadline instead of drifting past it.
  Future<RetrofitCapOutcome> capEnrollmentExpiry(String enrollmentId) async {
    final key = buildEnrollmentKey(enrollmentId);
    final AtData? atData;
    try {
      atData = await keyStore.get(key);
    } on KeyNotFoundException {
      return RetrofitCapOutcome.predecessorGone;
    }
    if (atData == null) return RetrofitCapOutcome.predecessorGone;

    // The status comes off the record JUST READ, never off [enrollment].
    // `put` moves an enrollment's per-enrollment data to match the status it
    // is handed, so a status from an older snapshot is not a cosmetic
    // mismatch: the caller reads the predecessor, then awaits a keystore walk
    // and a write of the successor before arriving here, and a revoke landing
    // in that window would be UNDONE — the data moved back to the approved
    // location, republishing the `_apsk` a revocation had just parked.
    final String? raw = atData.data;
    if (raw == null) return RetrofitCapOutcome.unreadable;
    final EnrollDataStoreValue fresh;
    final EnrollmentStatus? current;
    try {
      fresh = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      current =
          EnrollmentStatus.values.asNameMap()[fresh.approval?.state ?? ''];
    } catch (e) {
      logger.severe('Not capping $enrollmentId: its record does not decode: $e');
      return RetrofitCapOutcome.unreadable;
    }
    if (current == null) {
      logger.severe('Not capping $enrollmentId: unreadable approval state');
      return RetrofitCapOutcome.unreadable;
    }
    // Re-tested on the fresh read for the same reason. A predecessor that was
    // approved when the decision was made and is not approved now must not be
    // written back at all: capping is only ever meant to SHORTEN the life of a
    // working credential.
    if (current != EnrollmentStatus.approved) {
      logger.info(
          'Not capping $enrollmentId: it is ${current.name} as of this write, '
          'though it was approved when the cap was decided');
      return RetrofitCapOutcome.notApproved;
    }
    atData.metaData = (atData.metaData ?? AtMetaData())
      ..ttl = retrofitCapTtlMillis(
          atData.metaData, fresh, DateTime.now().toUtc());
    await put(enrollmentId, atData, current);
    return RetrofitCapOutcome.capped;
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
      // The generation the decision is READ at, not the one it finishes at.
      // Everything below this line awaits, and an enrollment write landing in
      // that window bumps the counter. Recording the post-bump value would
      // tell the next authentication that a change the decision never saw is
      // already accounted for, and the question would not be re-opened.
      final int decisionGeneration = cacheInvalidations;
      // The early exit goes through the cached read, because this runs on
      // EVERY APKAM authentication and all but a retrofit's successor leave
      // here. The PKAM path has just read this same enrollment, so it is warm.
      final EnrollDataStoreValue cached =
          await getEnrollmentById(successorEnrollmentId);
      final predecessorId = cached.parentEnrollmentId;
      if (predecessorId == null) return;
      if (cached.predecessorCapArmedAt != null) return;
      // Declined already, and nothing has been written since, so the answer
      // cannot have changed.
      if (declinedAtGeneration[successorEnrollmentId] == decisionGeneration) {
        return;
      }

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
          declinedAtGeneration[successorEnrollmentId] = decisionGeneration;
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
            declinedAtGeneration[successorEnrollmentId] = decisionGeneration;
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
        final RetrofitCapOutcome outcome =
            await capEnrollmentExpiry(predecessorId);
        // The stamp goes on BEFORE the cap deliberately — a capped predecessor
        // with no stamp is re-capped with a fresh full grace on every later
        // authentication and never retires. But that ordering means a cap
        // which declines leaves a stamp claiming the question is settled when
        // it is not, and the stamp is durable while the reason was transient:
        // the predecessor was approved when the decision was taken and had
        // been revoked by the time of the write. An un-revoke would then
        // restore it with no expiry and no successor able to re-arm, forever.
        //
        // So the stamp is taken back, and ONLY for that outcome. A predecessor
        // that is genuinely gone stays stamped: nothing can bring it back, and
        // re-walking the lookup on every future connection buys nothing.
        if (outcome == RetrofitCapOutcome.notApproved ||
            outcome == RetrofitCapOutcome.unreadable) {
          await _clearCapStamp(successorEnrollmentId, key);
          declinedAtGeneration[successorEnrollmentId] = decisionGeneration;
        }
      }
    } catch (e) {
      logger.warning('Could not arm the retrofit cap for '
          '$successorEnrollmentId: $e');
    }
  }
}
