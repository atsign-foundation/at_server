import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_revocation_event.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/apkam_signature_verifier.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';
import 'package:mutex/mutex.dart';
import 'package:uuid/uuid.dart';

/// What [EnrollmentManager.capEnrollmentExpiry] did.
enum RetrofitCapOutcome {
  /// The expiry was written.
  capped,

  /// The predecessor's record is gone, so the successor's stamp stands.
  predecessorGone,

  /// The predecessor was approved when the decision was made and is not now.
  notApproved,

  /// The record could not be read or decoded. Treated like [notApproved].
  unreadable,
}

/// An atSign's enrollment records: reading and writing them, and the
/// questions that have to be asked of the whole roster before a write.
class EnrollmentManager {
  final AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
  final String atSign;

  /// The atSign's ONE enrollment-mutation critical section; reads are
  /// deliberately outside it.
  final Mutex _mutationLock = Mutex();

  /// Marks the zone a [serialiseMutation] action runs in, so a nested
  /// mutation can be told from a genuinely concurrent one.
  static const Object _inMutationZoneKey = #atEnrollmentMutation;

  /// Runs [action] as this atSign's only in-flight enrollment mutation.
  ///
  /// Wrap the whole read-decide-write, never just the write; re-entrant, so
  /// an action reached from inside another one runs straight through.
  Future<T> serialiseMutation<T>(Future<T> Function() action) {
    if (Zone.current[_inMutationZoneKey] == true) return action();
    return _mutationLock.protect(
        () => runZoned(action, zoneValues: {_inMutationZoneKey: true}));
  }

  static int cacheHits = 0;
  static int cacheMisses = 0;
  static int cacheInvalidations = 0;

  final AtSignLogger logger = AtSignLogger('EnrollmentManager');

  /// Per enrollment key, the AtData as stored and its decoded json Map,
  /// invalidated by every enrollment write and by [postRemoveHook].
  final Map<String, (AtData, Map<String, dynamic>)> atDataCache = {};

  EnrollmentManager(this.keyStore, this.atSign);

  /// The enrollment [enId] names, an elapsed one reported `expired`. Throws
  /// [KeyNotFoundException] when there is no such record.
  Future<EnrollDataStoreValue> getEnrollmentById(String enId) async {
    return getEnrollmentByFullKey(buildEnrollmentKey(enId));
  }

  /// An enrollment id in the form the keystore holds it in.
  static String canonicalEnrollmentId(String enId) => canonicalAtKey(enId);

  /// [canonicalEnrollmentId] for a value that may be absent.
  static String? canonicalEnrollmentIdOrNull(String? enId) =>
      enId == null ? null : canonicalEnrollmentId(enId);

  /// The keystore key for enrollment [enId], byte-identical to what
  /// [getAllEnrollmentKeys] returns for that record.
  String buildEnrollmentKey(String enId) {
    return canonicalAtKey('${canonicalEnrollmentId(enId)}'
        '.${EnrollmentConstants.enrollmentKeyPattern}'
        '.${EnrollmentConstants.enrollManageNamespace}'
        '$atSign');
  }

  /// The id of the enrollment the atSign's flat legacy credential migrates
  /// into.
  static const String primaryEnrollmentId = 'primary';

  /// The app and device name [primaryEnrollmentId] is recorded under.
  static const String primaryEnrollmentName = 'legacy';

  /// The enrollment record [primaryEnrollmentId] names, or null when the
  /// atSign has never held one.
  Future<EnrollDataStoreValue?> primaryEnrollment() async {
    try {
      return await getEnrollmentById(primaryEnrollmentId);
    } on KeyNotFoundException {
      return null;
    }
  }

  /// Mints [primaryEnrollmentId] from [apkamPublicKey]: approved, `*:rw` and
  /// `__manage:rw`, no expiry, no parent and no predecessor.
  ///
  /// Exempt from the key-uniqueness rule, and must be called inside
  /// [serialiseMutation].
  Future<void> mintPrimary(String apkamPublicKey, {String? signingAlgo}) async {
    await _shoutOtherHoldersOf(apkamPublicKey, signingAlgo);
    final EnrollDataStoreValue value = EnrollDataStoreValue(
        primaryEnrollmentName,
        primaryEnrollmentName,
        primaryEnrollmentName,
        apkamPublicKey)
      ..namespaces = {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      }
      ..requestType = EnrollRequestType.newEnrollment
      ..approval = EnrollApproval(EnrollmentStatus.approved.name)
      ..signingAlgo = signingAlgo;
    await put(primaryEnrollmentId, AtData()..data = jsonEncode(value.toJson()),
        EnrollmentStatus.approved);
    logger.shout('Minted enrollment $primaryEnrollmentId from the atSign\'s '
        'flat legacy credential; a legacy pkam: now authenticates as it');
  }

  /// Rotates [primaryEnrollmentId] onto [apkamPublicKey], leaving everything
  /// else about the record as it stands, save that [reapprove] lifts a
  /// revoked primary back to approved.
  Future<void> _rotatePrimary(String apkamPublicKey, String? signingAlgo,
      EnrollDataStoreValue primary,
      {bool reapprove = false}) async {
    await _shoutOtherHoldersOf(apkamPublicKey, signingAlgo);
    primary
      ..apkamPublicKey = apkamPublicKey
      ..signingAlgo = signingAlgo;
    EnrollmentStatus status =
        EnrollmentStatus.values.asNameMap()[primary.approval?.state ?? ''] ??
            EnrollmentStatus.approved;
    if (reapprove && status == EnrollmentStatus.revoked) {
      status = EnrollmentStatus.approved;
      primary.approval = EnrollApproval(EnrollmentStatus.approved.name);
      logger.info('Re-approved enrollment $primaryEnrollmentId: the caller '
          'holds the atSign\'s creation secret');
    }
    final String ek = buildEnrollmentKey(primaryEnrollmentId);
    final AtData record = (await keyStore.get(ek)) ?? AtData();
    record.data = jsonEncode(primary.toJson());
    final DateTime? storedExpiry = record.metaData?.expiresAt;
    await put(primaryEnrollmentId, record, status,
        assertedTimestamps: storedExpiry == null
            ? null
            : AtAssertedTimestamps(expiresAt: storedExpiry));
    logger.shout('Rotated enrollment $primaryEnrollmentId onto the key the '
        'atSign\'s flat legacy credential held');
  }

  Future<void> _shoutOtherHoldersOf(
      String apkamPublicKey, String? signingAlgo) async {
    for (final (String id, EnrollDataStoreValue value)
        in await storedEnrollments()) {
      if (id == primaryEnrollmentId) continue;
      if (sameApkamKeyMaterial(
          apkamPublicKey, signingAlgo, value.apkamPublicKey, value.signingAlgo)) {
        logger.shout('Enrollment $id (${value.approval?.state}) holds the '
            'same key as $primaryEnrollmentId; one keypair under two names. '
            'Revoke or delete whichever should not stand');
      }
    }
  }

  /// Removes the flat legacy credential from the store.
  Future<void> _deleteFlatKey() =>
      keyStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);

  /// Migrates the flat legacy credential into [primaryEnrollmentId] on the
  /// wire, minting or rotating `primary` and deleting the flat key in the
  /// same act.
  ///
  /// Returns whether there was a flat key to absorb.
  Future<bool> absorbFlatKeyIntoPrimary({String? signingAlgo}) =>
      serialiseMutation(() async {
        final String? flat = await legacyPkamPublicKey();
        if (flat == null) return false;
        final EnrollDataStoreValue? primary = await primaryEnrollment();
        if (primary == null) {
          await mintPrimary(flat, signingAlgo: signingAlgo);
        } else if (!sameApkamKeyMaterial(
            flat, signingAlgo, primary.apkamPublicKey, primary.signingAlgo)) {
          await _rotatePrimary(flat, signingAlgo, primary);
        }
        await _deleteFlatKey();
        return true;
      });

  /// Lifts a revoked [primaryEnrollmentId] back to approved, leaving its key
  /// material and its stored expiry as they stand.
  Future<void> _reapprovePrimary(EnrollDataStoreValue primary) async {
    primary.approval = EnrollApproval(EnrollmentStatus.approved.name);
    final String ek = buildEnrollmentKey(primaryEnrollmentId);
    final AtData record = (await keyStore.get(ek)) ?? AtData();
    record.data = jsonEncode(primary.toJson());
    final DateTime? storedExpiry = record.metaData?.expiresAt;
    await put(primaryEnrollmentId, record, EnrollmentStatus.approved,
        assertedTimestamps: storedExpiry == null
            ? null
            : AtAssertedTimestamps(expiresAt: storedExpiry));
    logger.shout('Re-approved enrollment $primaryEnrollmentId, which already '
        'holds the key being installed; the caller holds the atSign\'s '
        'creation secret');
  }

  /// Redirects a CRAM connection's `update` of the atSign's legacy credential
  /// into [primaryEnrollmentId], minting or rotating `primary`, re-approving
  /// a revoked `primary` whether it rotates or already holds the key, and
  /// writing no flat key.
  ///
  /// Throws [IllegalStateException] when a stored enrollment other than
  /// `primary` already holds the key, and [IllegalArgumentException] when
  /// the value is not APKAM key material.
  Future<void> installLegacyKeyIntoPrimary(String apkamPublicKey) =>
      serialiseMutation(() async {
        if (apkamPublicKey.trim().isEmpty ||
            apkamKeyMaterial(apkamPublicKey, null) == null) {
          throw IllegalArgumentException(
              'The value is not an APKAM public key: it does not decode as '
              'key material, and $primaryEnrollmentId would stand as an '
              'approved, unexpiring root nobody can authenticate as');
        }
        final (String, EnrollDataStoreValue)? holder =
            await holderOfApkamPublicKey(apkamPublicKey, null,
                excluding: primaryEnrollmentId);
        if (holder != null) {
          throw IllegalStateException(
              'The apkamPublicKey is already held by another enrollment on '
              'this atSign; every enrollment needs a keypair of its own '
              '(held by enrollment ${holder.$1}, ${holder.$2.approval?.state})');
        }
        final EnrollDataStoreValue? primary = await primaryEnrollment();
        if (primary == null) {
          await mintPrimary(apkamPublicKey);
        } else if (!sameApkamKeyMaterial(apkamPublicKey, null,
            primary.apkamPublicKey, primary.signingAlgo)) {
          await _rotatePrimary(apkamPublicKey, null, primary, reapprove: true);
        } else if (primary.approval?.state == EnrollmentStatus.revoked.name) {
          await _reapprovePrimary(primary);
        }
      });

  /// Migrates the flat legacy credential at startup, before any client
  /// connects, and reports what it found and did.
  Future<StartupFlatKeyOutcome> migrateFlatKeyAtStartup() =>
      serialiseMutation(_migrateFlatKeyAtStartupUnderLock);

  /// The startup migration: a flat key that is an approved or revoked root's
  /// copy is deleted where an unexpiring root survives the deletion, and any
  /// remaining flat key is migrated into `primary` or, where `primary` holds
  /// a different key, deleted.
  ///
  /// Must be called inside [serialiseMutation].
  Future<StartupFlatKeyOutcome> _migrateFlatKeyAtStartupUnderLock() async {
    final String? flat = await legacyPkamPublicKey();
    if (flat == null) {
      if (await keyStore.exists(AtConstants.atPkamPublicKey)) {
        await _deleteFlatKey();
        logger.info('Deleted an empty ${AtConstants.atPkamPublicKey}: a '
            'zero-length value is a credential nobody can authenticate with');
      }
      return StartupFlatKeyOutcome.none;
    }

    (String, EnrollDataStoreValue)? rootHolder;
    for (final (String id, EnrollDataStoreValue value)
        in await storedEnrollments()) {
      if (id == primaryEnrollmentId) continue;
      if (!value.isRootEnrollment) continue;
      final String? state = value.approval?.state;
      if (state != EnrollmentStatus.approved.name &&
          state != EnrollmentStatus.revoked.name) {
        continue;
      }
      if (sameApkamKeyMaterial(
          flat, value.signingAlgo, value.apkamPublicKey, value.signingAlgo)) {
        rootHolder = (id, value);
        break;
      }
    }
    if (rootHolder != null) {
      final (String id, EnrollDataStoreValue value) = rootHolder;
      if (await hasUnexpiringRootEnrollment({})) {
        await _deleteFlatKey();
        logger.shout('Deleted the flat legacy credential '
            '(${AtConstants.atPkamPublicKey}): it was a copy of the key '
            'enrollment $id (${value.approval?.state}) holds, and that '
            'enrollment is what a client should authenticate as');
        return StartupFlatKeyOutcome.deletedAsCopyOfRoot;
      }
    }

    final EnrollDataStoreValue? primary = await primaryEnrollment();
    if (primary == null) {
      if (rootHolder != null) {
        final (String id, EnrollDataStoreValue value) = rootHolder;
        logger.shout('The keypair of ${value.approval?.state} enrollment $id '
            'is reinstated as $primaryEnrollmentId because nothing else '
            'survives: no other approved, fully privileged enrollment '
            'without an expiry holds a key');
      }
      await mintPrimary(flat);
      await _deleteFlatKey();
      return StartupFlatKeyOutcome.migratedIntoPrimary;
    }
    await _deleteFlatKey();
    if (sameApkamKeyMaterial(
        flat, primary.signingAlgo, primary.apkamPublicKey, primary.signingAlgo)) {
      logger.info('Deleted the flat legacy credential: $primaryEnrollmentId '
          'already holds its key, so this was the residue of a migration '
          'that did not finish');
      return StartupFlatKeyOutcome.deletedAsResidue;
    }
    logger.shout('Deleted a flat legacy credential '
        '(${AtConstants.atPkamPublicKey}) that held a key '
        '$primaryEnrollmentId does not: a key lying in the store at startup '
        'is not an owner\'s act on the wire, and it is not absorbed. '
        '$primaryEnrollmentId is untouched'
        '${rootHolder == null ? '' : ', and the keypair of enrollment '
            '${rootHolder.$1} (${rootHolder.$2.approval?.state}) is not '
            'reinstated'}');
    return StartupFlatKeyOutcome.deletedAsStray;
  }

  /// The atSign's flat legacy PKAM credential, null when it is absent or
  /// zero-length.
  Future<String?> legacyPkamPublicKey() async {
    final AtData? record;
    try {
      record = await keyStore.get(AtConstants.atPkamPublicKey);
    } on KeyNotFoundException {
      return null;
    }
    final String? value = record?.data;
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Stores [atData] as enrollment [enId], first moving the enrollment's
  /// per-enrollment data to match [newStatus].
  ///
  /// A read-modify-write must pass the stored `expiresAt` as
  /// [assertedTimestamps], or the record's expiry clock restarts at this
  /// write.
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
  /// move.
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

  /// Moves everything in `<enId>.[ard].__e` to [to], and returns the keys
  /// that were moved.
  @visibleForTesting
  Future<List<String>> movePerEnrollmentData(
    String enId, {
    required String to,
  }) =>
      movePerEnrollmentDataFor({enId}, to: to);

  /// [movePerEnrollmentData] for several enrollments in ONE keystore pass.
  @visibleForTesting
  Future<List<String>> movePerEnrollmentDataFor(
    Set<String> enIds, {
    required String to,
  }) async {
    if (enIds.isEmpty) return [];
    // NOTE the ids are compared against key segments the keystore returned,
    // so they must be canonical.
    enIds = enIds.map(canonicalEnrollmentId).toSet();
    switch (to) {
      case EnrollmentConstants.perEnrollmentRevoked:
      case EnrollmentConstants.perEnrollmentDeleted:
      case EnrollmentConstants.perEnrollmentApproved:
        List<String> moved = [];
        final RegExp perEnrollmentRegex =
            RegExp(EnrollmentConstants.regexForPerEnrollmentNamespaces);
        await for (final String fromKey in await keyStore.getKeys(
            regex: EnrollmentConstants.regexForPerEnrollmentNamespaces)) {
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

  /// The keystore key holding enrollment [enId]'s encryption private key.
  String keyForPEK(String enId) =>
      canonicalAtKey('${canonicalEnrollmentId(enId)}'
          '.${AtConstants.defaultEncryptionPrivateKey}'
          '.${EnrollmentConstants.enrollManageNamespace}'
          '$atSign');

  /// [keyForPEK]'s counterpart for the self-encryption key.
  String keyForSEK(String enId) =>
      canonicalAtKey('${canonicalEnrollmentId(enId)}'
          '.${AtConstants.defaultSelfEncryptionKey}'
          '.${EnrollmentConstants.enrollManageNamespace}'
          '$atSign');

  /// The public key an older server published an enrollment's APKAM public
  /// key at, keyed by its client-chosen app and device names.
  String keyForLegacyPK(EnrollDataStoreValue enVal) => canonicalAtKey('public:'
      '${enVal.appName}.${enVal.deviceName}'
      '.pkam.${EnrollmentConstants.pkamNamespace}'
      '.__public_keys$atSign');

  final RegExp ekRegex = RegExp(EnrollmentConstants.regexForEnrollmentKey);

  /// Moves an enrollment's per-enrollment data to `perEnrollmentDeleted`,
  /// called before any key in the keystore is removed.
  Future preRemoveHook(String key, {required bool skipCommit}) async {
    if (ekRegex.hasMatch(key)) {
      await _preRemove(ek: key);
    }
  }

  /// Drops the cached enrollment, called after any key in the keystore is
  /// removed.
  Future<void> postRemoveHook(String key, {required bool skipCommit}) async {
    final String ek = canonicalAtKey(key);
    if (!ekRegex.hasMatch(ek)) {
      return;
    }
    cacheInvalidations++;
    atDataCache.remove(ek);
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

    final pekKey = keyForPEK(enId);
    if (await keyStore.exists(pekKey)) {
      logger.info('_preRemove: Removing $pekKey');
      await keyStore.remove(pekKey, skipCommit: true);
    } else {
      logger.info('_preRemove: $pekKey has already been removed');
    }

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

  /// Deletes enrollment [enId]'s record.
  ///
  /// Throws [StateError] unless the pre- and post-remove hooks are active.
  Future<void> remove({required String enId}) async {
    if (!keyStore.preRemoveHooks.contains(preRemoveHook) ||
        !keyStore.postRemoveHooks.contains(postRemoveHook)) {
      throw StateError('Managing datastore consistency for enrollments requires'
          ' that the preRemoveHook and the postRemoveHook be active');
    }
    String ek = buildEnrollmentKey(enId);

    // NOTE cache invalidation is [postRemoveHook]'s, not this path's.
    await keyStore.remove(ek, skipCommit: true);
  }

  /// Every enrollment record key this atSign holds: the VISIBLE roster when
  /// [includeExpired] is false, the STORED roster when it is true.
  ///
  /// Anything deciding what the atSign IS must take the stored roster;
  /// anything merely reporting one can take the visible roster.
  Future<List<String>> getAllEnrollmentKeys(
      {required bool includeExpired}) async {
    if (!includeExpired) {
      return (await keyStore
              .getKeys(regex: EnrollmentConstants.enrollmentsRegex))
          .toList();
    }
    // NOTE `getKeys` has no include-expired form; `scanKeys` has.
    final RegExp re = RegExp(EnrollmentConstants.enrollmentsRegex);
    final List<String> keys = [];
    await for (final String key in await keyStore.scanKeys(const KeyPattern(),
        includeExpired: true)) {
      if (re.hasMatch(key)) keys.add(key);
    }
    return keys;
  }

  /// Every stored enrollment as its id and decoded value, expired records
  /// included and each reporting its state as `expired`.
  ///
  /// A record swept between the listing and the read is skipped, and so is
  /// one that does not decode; a store fault is not caught.
  Future<List<(String, EnrollDataStoreValue)>> storedEnrollments() async {
    final List<(String, EnrollDataStoreValue)> out = [];
    for (final String ek in await getAllEnrollmentKeys(includeExpired: true)) {
      try {
        out.add((getIdFromKey(ek), await getEnrollmentByFullKey(ek)));
      } on KeyNotFoundException {
        continue;
      } on FormatException catch (e) {
        logger.severe('Enrollment $ek does not decode and is left out of '
            'the stored roster: $e');
      } on TypeError catch (e) {
        logger.severe('Enrollment $ek does not decode and is left out of '
            'the stored roster: $e');
      }
    }
    return out;
  }

  /// The stored enrollment, in ANY status, holding the key material that
  /// [apkamPublicKey] spells under [signingAlgo]; null when none does.
  ///
  /// [excluding] is the enrollment re-sending its own current key, which is
  /// not a collision with itself.
  Future<(String, EnrollDataStoreValue)?> holderOfApkamPublicKey(
      String apkamPublicKey, String? signingAlgo,
      {String? excluding}) async {
    final String? excluded =
        excluding == null ? null : canonicalEnrollmentId(excluding);
    for (final (String id, EnrollDataStoreValue value)
        in await storedEnrollments()) {
      if (id == excluded) continue;
      // NOTE with no algorithm named, the holder's own is what its stored
      // spelling decodes under.
      if (sameApkamKeyMaterial(apkamPublicKey, signingAlgo ?? value.signingAlgo,
          value.apkamPublicKey, value.signingAlgo)) {
        return (id, value);
      }
    }
    return null;
  }

  /// The bytes [publicKey] spells under [signingAlgo]: hex, in either case,
  /// for `ecc_secp256r1`, base64 otherwise, and null when it does not decode
  /// as that.
  static List<int>? apkamKeyMaterial(String publicKey, String? signingAlgo) {
    final String spelled = publicKey.trim();
    if (signingAlgo == ApkamSignatureVerifier.eccAlgo) {
      if (spelled.length.isOdd ||
          !RegExp(r'^[0-9a-fA-F]+$').hasMatch(spelled)) {
        return null;
      }
      return List<int>.generate(spelled.length ~/ 2,
          (i) => int.parse(spelled.substring(2 * i, 2 * i + 2), radix: 16));
    }
    try {
      return base64Decode(spelled);
    } on FormatException {
      return null;
    }
  }

  /// True when the two spellings name the same key material: equal decoded
  /// bytes where both decode under their own algorithm, and equal trimmed
  /// text otherwise.
  static bool sameApkamKeyMaterial(
      String a, String? algoA, String b, String? algoB) {
    final List<int>? bytesA = apkamKeyMaterial(a, algoA);
    final List<int>? bytesB = apkamKeyMaterial(b, algoB);
    if (bytesA != null && bytesB != null) {
      if (bytesA.length != bytesB.length) return false;
      for (int i = 0; i < bytesA.length; i++) {
        if (bytesA[i] != bytesB[i]) return false;
      }
      return true;
    }
    return a.trim() == b.trim();
  }

  /// The enrollment stored at [ek], an elapsed one reported `expired` and
  /// left where it is. Throws [KeyNotFoundException] when there is none.
  Future<EnrollDataStoreValue> getEnrollmentByFullKey(
    String ek,
  ) async {
    AtData enrollData;
    Map<String, dynamic> enrollJson;

    if (atDataCache.containsKey(ek)) {
      cacheHits++;
      (enrollData, enrollJson) = atDataCache[ek]!;
    } else {
      cacheMisses++;
      // NOTE the value must not be cached when a write landed while the read
      // below was in flight.
      final int generationAtRead = cacheInvalidations;
      enrollData = (await keyStore.get(ek))!;
      enrollJson = jsonDecode(enrollData.data!);
      if (cacheInvalidations == generationAtRead) {
        atDataCache[ek] = (enrollData, enrollJson);
      }
    }

    EnrollDataStoreValue value = EnrollDataStoreValue.fromJson(enrollJson);
    if (!SecondaryUtil.isActiveKey(enrollData)) {
      logger.finer('getEnrollmentByFullKey:'
          ' Enrollment $ek has expired - reporting it expired. The scheduled'
          ' expired-keys pass is what removes it');
      value.approval = EnrollApproval(EnrollmentStatus.expired.name);
    }
    return value;
  }

  /// When the record for [enrollmentKey] stops being served, in UTC, or null
  /// when it never does.
  Future<DateTime?> effectiveExpiryOf(String enrollmentKey) async =>
      (await keyStore.get(enrollmentKey))?.metaData?.expiresAt?.toUtc();

  /// The wire form of [effectiveExpiryOf]: ISO-8601 in UTC, or null.
  static String? expiresAtField(DateTime? expiry) =>
      expiry?.toUtc().toIso8601String();

  /// The enrollments whose keys are in [ekList], filtered to those whose
  /// status is in [statuses], each entry carrying `expiresAt`.
  ///
  /// [redactSecrets] selects the roster projection
  /// ([EnrollDataStoreValue.toJsonRoster]) instead of the full record, which
  /// carries the wrapped APKAM symmetric key.
  Future<Map<String, Map<String, dynamic>>> getEnrollmentsAsJson(
      {required bool redactSecrets,
      List<String>? ekList,
      List<EnrollmentStatus>? statuses}) async {
    ekList ??= await getAllEnrollmentKeys(includeExpired: false);

    Map<String, Map<String, dynamic>> ejList = {};
    for (var ek in ekList) {
      EnrollDataStoreValue enVal;
      try {
        enVal = await getEnrollmentByFullKey(ek);
      } on KeyNotFoundException {
        continue;
      }
      if (statuses == null ||
          statuses.contains(
              EnrollmentStatus.values.byName(enVal.approval!.state))) {
        final Map<String, dynamic> entry =
            redactSecrets ? enVal.toJsonRoster() : enVal.toJsonExtended();
        final DateTime? expiry;
        try {
          expiry = await effectiveExpiryOf(ek);
        } on KeyNotFoundException {
          continue;
        }
        entry['expiresAt'] = expiresAtField(expiry);
        ejList[ek] = entry;
      }
    }
    return ejList;
  }

  /// The access [enVal] holds over [namespace], or null if it holds none.
  ///
  /// A `*` grant covers every namespace, and a grant on a parent segment
  /// covers its children (`wavi` covers `data.wavi`).
  String? accessForNamespace(EnrollDataStoreValue enVal, String namespace) =>
      accessInNamespaces(enVal.namespaces, namespace);

  /// [accessForNamespace] over a bare grants map.
  String? accessInNamespaces(Map<String, String> namespaces, String namespace) {
    // NOTE an explicit grant wins; `*` is only a fallback, so it must not be
    // matched inside the loop.
    for (final entry in namespaces.entries) {
      final ns = entry.key;
      if (ns == EnrollmentConstants.allNamespaces) continue;
      if (ns == namespace || namespace.endsWith('.$ns')) {
        return entry.value;
      }
    }
    return namespaces[EnrollmentConstants.allNamespaces];
  }

  /// The approved enrollments holding [namespace], each as the
  /// `enrollmentId`, `access`, `apkamPubKey` and opaque `metadata` the
  /// `enroll:listns` response carries.
  Future<List<Map<String, dynamic>>> getEnrollmentsForNamespace(
      String namespace) async {
    final result = <Map<String, dynamic>>[];
    for (final ek in await getAllEnrollmentKeys(includeExpired: false)) {
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
  /// An un-revoke withdraws a revocation here, so the value can move
  /// BACKWARDS: a client must ask whether it changed, not whether it grew.
  Future<DateTime?> lastRevocationForNamespace(String namespace) async {
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
      // NOTE a tie counts as withdrawn.
      if (withdrawn != null && !withdrawn.isBefore(entry.value.at)) continue;
      if (accessInNamespaces(entry.value.namespaces, namespace) == null) {
        continue;
      }
      final DateTime at = entry.value.at;
      if (latest == null || at.isAfter(latest)) latest = at;
    }
    return latest;
  }

  /// The at-rest key pattern for a revocation-history record, deliberately
  /// not built on [EnrollmentConstants.enrollmentKeyPattern].
  static const String revocationEventKeyPattern = 'revocation.events';

  static const String revocationEventsRegex =
      '\\.revocation\\.events\\.${EnrollmentConstants.enrollManageNamespace}@';

  String buildRevocationEventKey(String eventId) => '$eventId'
      '.$revocationEventKeyPattern'
      '.${EnrollmentConstants.enrollManageNamespace}'
      '$atSign';

  /// Appends [events] to the revocation history, one record each under a
  /// fresh id and with no ttl.
  Future<void> recordRevocationEvents(
      List<EnrollmentRevocationEvent> events) async {
    for (final EnrollmentRevocationEvent event in events) {
      await keyStore.put(buildRevocationEventKey(Uuid().v4()),
          AtData()..data = jsonEncode(event.toJson()),
          skipCommit: true);
    }
  }

  /// Every revocation event the atSign holds, in no particular order, a
  /// record that cannot be read logged and skipped.
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

  /// Removes the public key that leaks each enrollment's appName and
  /// deviceName, over the STORED roster.
  Future<List<String>> removeLegacyApkamPublicKeys() async {
    final List<String> deletedLegacyKeys = [];
    final eks = await getAllEnrollmentKeys(includeExpired: true);
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

  /// Removes the encryption keys of enrollments that no longer exist.
  Future<List<String>> removeOrphanedApkamEncryptionKeys() async {
    final List<String> deletedOrphanedKeys = [];
    final List<String> enIds = [];
    for (final ek in await getAllEnrollmentKeys(includeExpired: true)) {
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
  /// `min(grace, what the enrollment's own key-expiry posture leaves it)`,
  /// floored at one millisecond because a ttl of zero never expires.
  @visibleForTesting
  int retrofitCapTtlMillis(AtMetaData? recordMetaData,
      EnrollDataStoreValue enrollment, DateTime now) {
    int cappedTtl =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;
    final ownMs = enrollment.apkamKeysExpiryDuration.inMilliseconds;
    final stored = recordMetaData?.expiresAt?.toUtc();
    // NOTE a record with no stored expiry never expires, whatever posture its
    // value carries, so it must not be folded against one.
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

  /// Whether any enrollment outside [excluding] is an APPROVED root that will
  /// NOT expire: `rw` on both `*` and `__manage`, and no expiry at all.
  ///
  /// ⚠️ [excluding] must name every enrollment the act is about to take, a
  /// cascade's whole set included, since those are still `approved` on disk
  /// while this runs.
  Future<bool> hasUnexpiringRootEnrollment(Set<String> excluding) async {
    final excludedKeys = excluding.map(buildEnrollmentKey).toSet();
    for (final ek in await getAllEnrollmentKeys(includeExpired: true)) {
      if (excludedKeys.contains(ek)) continue;
      final EnrollDataStoreValue other;
      try {
        other = await getEnrollmentByFullKey(ek);
      } on KeyNotFoundException {
        continue;
      }
      if (other.approval?.state != EnrollmentStatus.approved.name) continue;
      if (!isUsableRootEnrollment(getIdFromKey(ek), other)) continue;
      final AtData? record;
      try {
        record = await keyStore.get(ek);
      } on KeyNotFoundException {
        continue;
      }
      if (record?.metaData?.expiresAt == null) return true;
    }
    return false;
  }

  /// Whether [value] is a root the atSign could fall back on: fully
  /// privileged AND with a non-empty public key recorded for it.
  ///
  /// ⚠️ It does NOT establish that anybody holds the private half.
  bool isUsableRootEnrollment(
      String enrollmentId, EnrollDataStoreValue value) {
    if (!value.isRootEnrollment) return false;
    return value.apkamPublicKey.isNotEmpty;
  }

  /// Which of [enrollmentIds] are usable roots ([isUsableRootEnrollment]) and
  /// currently approved, that is, which of them a revoke of that set would
  /// actually take away.
  Future<List<String>> approvedRootEnrollmentsAmong(
      Iterable<String> enrollmentIds) async {
    final List<String> roots = [];
    for (final id in enrollmentIds) {
      final AtData? record;
      try {
        record = await keyStore.get(buildEnrollmentKey(id));
      } on KeyNotFoundException {
        continue;
      }
      final String? raw = record?.data;
      if (raw == null) continue;
      final EnrollDataStoreValue value;
      try {
        value = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      } catch (e) {
        logger.severe('Could not decode enrollment $id while deciding '
            'whether an act removes a fully privileged enrollment: $e');
        continue;
      }
      if (value.approval?.state != EnrollmentStatus.approved.name) continue;
      if (isUsableRootEnrollment(id, value)) roots.add(id);
    }
    return roots;
  }

  /// The enrollment that APPROVED [id], not the one [id] replaced, read
  /// straight off the stored record so that the walk crosses an expired
  /// link.
  Future<String?> _approverIdOf(String id, Map<String, String?> memo) async {
    if (memo.containsKey(id)) return memo[id];
    String? approverId;
    try {
      final AtData? record = await keyStore.get(buildEnrollmentKey(id));
      final String? raw = record?.data;
      if (raw != null) {
        approverId = canonicalEnrollmentIdOrNull(
            EnrollDataStoreValue.fromJson(jsonDecode(raw))
                .parentEnrollmentId);
      }
    } on KeyNotFoundException {
      approverId = null;
    } on FormatException catch (e) {
      logger.severe('Enrollment $id does not decode; treating it as the end '
          'of the chain it is in: $e');
      approverId = null;
    }
    // NOTE a store fault is deliberately not caught.
    memo[id] = approverId;
    return approverId;
  }

  /// Every enrollment that reaches [enrollmentId] by following APPROVER links
  /// upward, to any depth, in any status. Never contains [enrollmentId], and
  /// never follows the replacement edge.
  ///
  /// ⚠️ A severed link orphans everything behind it, because nothing records
  /// ancestry beyond an enrollment's immediate approver.
  Future<Set<String>> descendantsOf(String enrollmentId) async {
    enrollmentId = canonicalEnrollmentId(enrollmentId);
    final Set<String> found = {};
    final Map<String, String?> memo = {};
    for (final ek in await getAllEnrollmentKeys(includeExpired: true)) {
      final String candidate = getIdFromKey(ek);
      if (candidate == enrollmentId) continue;
      // NOTE `seen` terminates the climb over stored data.
      final Set<String> seen = {candidate};
      String? current = await _approverIdOf(candidate, memo);
      while (current != null && seen.add(current)) {
        if (current == enrollmentId) {
          found.add(candidate);
          break;
        }
        current = await _approverIdOf(current, memo);
      }
    }
    return found;
  }

  /// Moves every enrollment [predecessorId] approved onto [successorId],
  /// never onto itself.
  ///
  /// Must be called inside [serialiseMutation]: this pass's omissions are
  /// permanent, because nothing ever re-parents twice.
  Future<void> _adoptApprovalChildren(
      String predecessorId, String successorId) async {
    for (final ek in await getAllEnrollmentKeys(includeExpired: true)) {
      final String childId = getIdFromKey(ek);
      if (childId == successorId) continue;
      final AtData? record;
      try {
        record = await keyStore.get(ek);
      } on KeyNotFoundException {
        continue;
      }
      final String? raw = record?.data;
      if (record == null || raw == null) continue;
      final EnrollDataStoreValue child;
      try {
        child = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      } catch (e) {
        logger.warning('Not re-parenting $childId onto $successorId: its '
            'record could not be decoded: $e');
        continue;
      }
      if (canonicalEnrollmentIdOrNull(child.parentEnrollmentId) !=
          canonicalEnrollmentIdOrNull(predecessorId)) {
        continue;
      }

      final EnrollmentStatus? status =
          EnrollmentStatus.values.asNameMap()[child.approval?.state ?? ''];
      if (status == null) {
        logger.warning('Not re-parenting $childId onto $successorId: its '
            'approval state ${child.approval?.state} is unreadable');
        continue;
      }

      child.parentEnrollmentId = successorId;
      record.data = jsonEncode(child.toJson());
      // NOTE the child's own expiry must not move.
      final DateTime? storedExpiry = record.metaData?.expiresAt;
      await put(childId, record, status,
          assertedTimestamps: storedExpiry == null
              ? null
              : AtAssertedTimestamps(expiresAt: storedExpiry));
      logger.info('Enrollment $childId was approved by $predecessorId, which '
          'has just been capped; it now hangs off its successor $successorId');
    }
  }

  /// Revokes each of [enrollmentIds] that is currently approved, and returns
  /// the ids it actually revoked.
  ///
  /// [byEnrollmentId] is the enrollment on the connection that issued the
  /// command, null for a CRAM connection; [cascadedFrom] is the enrollment it
  /// named; [at] is the moment of the command, one timestamp for the set.
  Future<List<String>> revokeAll(Iterable<String> enrollmentIds,
      {required String? byEnrollmentId,
      required String cascadedFrom,
      required DateTime at}) async {
    final List<String> revoked = [];
    // The grants each one held, captured before the write, because the event
    // outlives the record they are stored on.
    final Map<String, Map<String, String>> grantsHeld = {};
    final Map<String, AtData> pending = {};
    for (final id in enrollmentIds) {
      final ek = buildEnrollmentKey(id);
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

    // NOTE the history goes in before the records change.
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

    // One pass for every enrollment the cascade takes, then the records.
    await movePerEnrollmentDataFor(revoked.toSet(),
        to: EnrollmentConstants.perEnrollmentRevoked);
    for (final id in revoked) {
      final AtData atData = pending[id]!;
      // NOTE a revoke says nothing about expiry, so the stored expiry is
      // asserted back on each write.
      final storedExpiry = atData.metaData?.expiresAt;
      await _writeEnrollmentRecord(id, atData,
          assertedTimestamps: storedExpiry == null
              ? null
              : AtAssertedTimestamps(expiresAt: storedExpiry));
    }
    return revoked;
  }

  /// Takes back a `predecessorCapArmedAt` stamp whose cap did not happen,
  /// best-effort and inside [serialiseMutation].
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
  Future<RetrofitCapOutcome> capEnrollmentExpiry(String enrollmentId) async {
    final key = buildEnrollmentKey(enrollmentId);
    final AtData? atData;
    try {
      atData = await keyStore.get(key);
    } on KeyNotFoundException {
      return RetrofitCapOutcome.predecessorGone;
    }
    if (atData == null) return RetrofitCapOutcome.predecessorGone;

    // NOTE the status must come off the record just read, never off a
    // caller's snapshot.
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

  /// Settles what the enrollment [successorEnrollmentId] replaced, ONCE, at
  /// the successor's first authentication: the successor is stamped, the
  /// predecessor's approval children move onto it, and a predecessor that is
  /// not fully privileged is capped.
  ///
  /// A no-op for an enrollment that replaced nothing, and it never throws.
  Future<void> armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
    try {
      final EnrollDataStoreValue cached =
          await getEnrollmentById(successorEnrollmentId);
      if (cached.retrofitPredecessorEnrollmentId == null) return;
      if (cached.predecessorCapArmedAt != null) return;
    } catch (e) {
      logger.warning('Could not decide whether to arm the retrofit cap for '
          '$successorEnrollmentId: $e');
      return;
    }
    await serialiseMutation(
        () => _armRetrofitCapOnFirstAuth(successorEnrollmentId));
  }

  Future<void> _armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
    try {
      // NOTE both tests are re-asked here, inside the critical section.
      final EnrollDataStoreValue cached =
          await getEnrollmentById(successorEnrollmentId);
      final predecessorId = cached.retrofitPredecessorEnrollmentId;
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

      bool settled = false;
      bool capPredecessor = false;
      final bool predecessorGone = predecessor == null;

      if (predecessorGone) {
        settled = true;
      } else if (predecessor.approval?.state != EnrollmentStatus.approved.name) {
        // NOTE deliberately left unstamped, so the question is re-asked at
        // the next authentication.
        logger.info('Enrollment $successorEnrollmentId replaced $predecessorId, '
            'which is ${predecessor.approval?.state} — not capping it');
      } else if (predecessor.isRootEnrollment) {
        logger.info('Enrollment $successorEnrollmentId replaced $predecessorId, '
            'which holds full privilege and keeps its life; what it admitted '
            'now hangs off its successor');
        settled = true;
      } else {
        settled = true;
        capPredecessor = true;
      }

      if (!settled) return;

      // NOTE read immediately before the write, not from a snapshot taken
      // before the lookups above.
      final AtData? atData = await keyStore.get(key);
      final String? raw = atData?.data;
      if (atData == null || raw == null) return;
      final successor = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      // NOTE this uncached re-test is what makes "first" hold; the cached
      // checks at the entry point are only a fast path.
      if (successor.predecessorCapArmedAt != null) return;

      successor.predecessorCapArmedAt = DateTime.now().toUtc();
      atData.data = jsonEncode(successor.toJson());
      // NOTE the successor's own expiry must not move.
      final storedExpiry = atData.metaData?.expiresAt;
      // NOTE the record's own status, never a default.
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

      // NOTE the cap goes after the stamp.
      if (capPredecessor) {
        final RetrofitCapOutcome outcome =
            await capEnrollmentExpiry(predecessorId);
        // NOTE a transient refusal takes the stamp back, so the question is
        // re-asked at the next authentication.
        if (outcome == RetrofitCapOutcome.notApproved ||
            outcome == RetrofitCapOutcome.unreadable) {
          await _clearCapStamp(successorEnrollmentId, key);
          return;
        }
      }
      await _adoptApprovalChildren(predecessorId, successorEnrollmentId);
    } catch (e) {
      logger.warning('Could not arm the retrofit cap for '
          '$successorEnrollmentId: $e');
    }
  }
}

/// What [EnrollmentManager.migrateFlatKeyAtStartup] did about the flat legacy
/// credential.
enum StartupFlatKeyOutcome {
  /// No flat key was stored.
  none,

  /// A copy of a root's key, with another unexpiring root surviving: deleted.
  deletedAsCopyOfRoot,

  /// Minted `primary` from it, then deleted it.
  migratedIntoPrimary,

  /// `primary` already held it, a migration that did not finish: deleted.
  deletedAsResidue,

  /// `primary` holds a different key: deleted and logged, `primary` untouched.
  deletedAsStray,
}
