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

/// What [EnrollmentManager.capEnrollmentExpiry] did. Its caller needs this to
/// decide whether the successor's "I have settled this" stamp is honest: a
/// stamp left standing over a cap that did not happen is permanent, and the
/// predecessor would then keep an uncapped credential forever.
enum RetrofitCapOutcome {
  /// The expiry was written.
  capped,

  /// The predecessor's record is gone, so the successor's stamp stands.
  predecessorGone,

  /// The predecessor was approved when the decision was made and is not now.
  /// Transient, so the stamp must NOT stand.
  notApproved,

  /// The record could not be read or decoded. Treated like [notApproved].
  unreadable,
}

/// An atSign's enrollment records: reading and writing them, and the
/// questions that have to be asked of the whole roster before a write.
class EnrollmentManager {
  final AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
  final String atSign;

  /// The atSign's ONE enrollment-mutation critical section.
  ///
  /// Store-wide rather than per record, because every enrollment mutation is
  /// a read-decide-write over a keystore with no compare-and-set and the
  /// decision rests on a question about the WHOLE roster ("would any
  /// unexpiring root survive this act?"). Two mutations of two DIFFERENT
  /// records each pass an individually correct check and strand the atSign
  /// between them, which a per-record lock cannot see. It closes the plain
  /// lost update too: whole-record snapshots, so whichever wrote second would
  /// reinstate what the other had just left.
  ///
  /// READS are deliberately outside it: they happen on every verb command and
  /// every authorisation check, so serialising them would put the whole
  /// atSign behind one queue. A reader can observe a cascade part-applied,
  /// and that is only safe while a read stays read-only.
  final Mutex _mutationLock = Mutex();

  /// Marks the zone a [serialiseMutation] action runs in, so a mutation
  /// reached from INSIDE another one can be told from a genuinely concurrent
  /// one. Zone values propagate across every await, which is what makes the
  /// distinction hold for asynchronous code.
  static const Object _inMutationZoneKey = #atEnrollmentMutation;

  /// Runs [action] as this atSign's only in-flight enrollment mutation.
  ///
  /// Wrap the whole read-decide-write, never just the write. The write is not
  /// what races; the decision the write rests on is.
  ///
  /// RE-ENTRANT, which [Mutex.protect] is not: a nested `protect` never
  /// completes, so a nesting mistake costs a permanent hang on the
  /// authentication path rather than a wrong answer. An action reached from
  /// inside another one runs straight through; a genuinely concurrent caller
  /// arrives in a different zone and waits.
  Future<T> serialiseMutation<T>(Future<T> Function() action) {
    if (Zone.current[_inMutationZoneKey] == true) return action();
    return _mutationLock.protect(
        () => runZoned(action, zoneValues: {_inMutationZoneKey: true}));
  }

  static int cacheHits = 0;
  static int cacheMisses = 0;
  static int cacheInvalidations = 0;

  final AtSignLogger logger = AtSignLogger('EnrollmentManager');

  /// Per enrollment key, the AtData as stored and its decoded json Map. The
  /// AtData is what `isActiveKey` can be checked against; the Map saves a
  /// jsonDecode per read. The Map rather than an EnrollDataStoreValue because
  /// that value is mutable, and a caller mutating one would pollute the cache.
  ///
  /// Read by [getEnrollmentByFullKey]; invalidated by every enrollment write
  /// and by [postRemoveHook] for every removal of an enrollment key, however
  /// that removal was reached ([remove], the `delete` verb, or the scheduled
  /// expired-keys sweep). Enrollments are read on every verb command and every
  /// authorisation check and written very rarely, which is why there is a
  /// cache here at all.
  final Map<String, (AtData, Map<String, dynamic>)> atDataCache = {};

  EnrollmentManager(this.keyStore, this.atSign);

  /// The enrollment [enId] names. Throws [KeyNotFoundException] when there is
  /// no such record.
  ///
  /// A record whose ttl has elapsed is reported with status `expired` and is
  /// left where it is; see [getEnrollmentByFullKey].
  Future<EnrollDataStoreValue> getEnrollmentById(String enId) async {
    return getEnrollmentByFullKey(buildEnrollmentKey(enId));
  }

  /// An enrollment id in the form the keystore holds it in.
  ///
  /// An id is a key COMPONENT, so the keystore's fold applies to it whether
  /// or not anything above the keystore folds: `' Abc'`, `'A bc'` and `'abc'`
  /// all address one record. Comparisons above the store are exact
  /// `String ==`, so a handler holding an unfolded spelling would ask about a
  /// string that is not on disk while reading and writing the record that is.
  ///
  /// Via [canonicalAtKey], so the answer is the keystore's own. Folding
  /// rather than refusing a non-canonical spelling cannot widen which record
  /// a caller reaches, since the keystore already resolves one to the same
  /// record.
  static String canonicalEnrollmentId(String enId) => canonicalAtKey(enId);

  /// [canonicalEnrollmentId] for a value that may be absent, so that an entry
  /// point reading an optional id from the wire can fold it in one step.
  static String? canonicalEnrollmentIdOrNull(String? enId) =>
      enId == null ? null : canonicalEnrollmentId(enId);

  /// The keystore key for enrollment [enId].
  ///
  /// CANONICAL: byte-identical to what an enumeration such as
  /// [getAllEnrollmentKeys] returns for that record, which is what lets a key
  /// built here be COMPARED against an enumerated one. [excluding] in
  /// [hasUnexpiringRootEnrollment] does exactly that, and a key matching
  /// nothing there makes the last-root refusal count the enrollment the act
  /// is removing.
  ///
  /// The id is folded BEFORE composition as well as after: composition moves
  /// whatever TRAILS the id into the middle of the key, where the fold's trim
  /// can no longer reach it and only a plain space is stripped.
  String buildEnrollmentKey(String enId) {
    return canonicalAtKey('${canonicalEnrollmentId(enId)}'
        '.${EnrollmentConstants.enrollmentKeyPattern}'
        '.${EnrollmentConstants.enrollManageNamespace}'
        '$atSign');
  }

  /// The id of the enrollment the atSign's flat legacy credential migrates
  /// into. A literal, so that a client sending no id and a client sending
  /// this one authenticate as the same record.
  static const String primaryEnrollmentId = 'primary';

  /// What [primaryEnrollmentId] is recorded as: the app and device names an
  /// owner sees in the roster for the credential they onboarded with.
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
  /// `__manage:rw`, no expiry, named [primaryEnrollmentName] as both app and
  /// device, with no parent and no predecessor. [signingAlgo] is the
  /// algorithm the key verified under on the wire, or null for a key found in
  /// the store, which every reader treats as `rsa2048` unless the wire says
  /// otherwise.
  ///
  /// EXEMPT from the key-uniqueness rule: this mints from a key the
  /// connection just proved, or that the store already holds, whatever else
  /// holds it. Every other holder is logged at shout instead.
  ///
  /// Must be called inside [serialiseMutation].
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
  /// else about the record, its status included, as it stands. Same
  /// exemption and the same logging as [mintPrimary].
  Future<void> _rotatePrimary(String apkamPublicKey, String? signingAlgo,
      EnrollDataStoreValue primary) async {
    await _shoutOtherHoldersOf(apkamPublicKey, signingAlgo);
    primary
      ..apkamPublicKey = apkamPublicKey
      ..signingAlgo = signingAlgo;
    final EnrollmentStatus status =
        EnrollmentStatus.values.asNameMap()[primary.approval?.state ?? ''] ??
            EnrollmentStatus.approved;
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

  /// Removes the flat legacy credential from the store. Nothing on the wire
  /// can put it back; see `AbstractVerbHandler.refuseFlatCredentialWrite`.
  Future<void> _deleteFlatKey() =>
      keyStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);

  /// Migrates the flat legacy credential into [primaryEnrollmentId] on the
  /// wire: mints `primary` from it when absent, rotates `primary` onto it when
  /// present with a different key, and deletes the flat key in the same act,
  /// so there is one credential and one record from that moment on. Returns
  /// whether there was a flat key to absorb.
  ///
  /// Called by a legacy `pkam:` that has just verified against the flat key.
  /// [signingAlgo] is what the wire said the key was, recorded on `primary`
  /// so later logins are judged under the algorithm the key really is. A
  /// crash between the mint and the deletion leaves both, which
  /// [migrateFlatKeyAtStartup] resolves at the next startup.
  ///
  /// Inside the enrollment-mutation section: a second legacy login waiting on
  /// it finds no flat key and verifies against the record this one wrote.
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

  /// The one carve-out from the flat credential's write ban, redirected: a
  /// CRAM connection's `update` of the atSign's legacy credential mints
  /// [primaryEnrollmentId] from [apkamPublicKey] when `primary` is absent and
  /// rotates `primary` onto it when it is present. No flat key is written, so
  /// none exists on a running server. See
  /// `AbstractVerbHandler.refuseFlatCredentialWrite`, which admits exactly
  /// that one write.
  ///
  /// Subject to key uniqueness like any `enroll:update`: refused, with
  /// nothing written, when a stored enrollment other than `primary` holds the
  /// key.
  Future<void> installLegacyKeyIntoPrimary(String apkamPublicKey) =>
      serialiseMutation(() async {
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
          await _rotatePrimary(apkamPublicKey, null, primary);
        }
      });

  /// Migrates the flat legacy credential at startup, before any client
  /// connects, and reports what it found and did.
  Future<StartupFlatKeyOutcome> migrateFlatKeyAtStartup() =>
      serialiseMutation(_migrateFlatKeyAtStartupUnderLock);

  /// The startup migration, in two steps inside the enrollment-mutation
  /// section.
  ///
  /// FIRST, a flat key that is some root's copy is deleted, but only if the
  /// stranding question says an approved, fully privileged, unexpiring
  /// enrollment with a non-empty key survives the deletion; otherwise the key
  /// is migrated instead, a case reachable only where the root's own keypair
  /// revoked itself. Root grants only, because a subordinate must not be able
  /// to trigger this: an OTP request takes a client-chosen key, and only a
  /// root can approve a root-granted record. Approved or revoked only,
  /// because only a record that was once approved was ever a root.
  ///
  /// SECOND, any remaining flat key is migrated as [absorbFlatKeyIntoPrimary]
  /// migrates one, except that a flat key found beside an existing `primary`
  /// holding a DIFFERENT key is deleted and logged rather than absorbed: a
  /// key lying in the store at startup is not an owner's act on the wire.
  ///
  /// After this, no flat key exists on a running server.
  Future<StartupFlatKeyOutcome> _migrateFlatKeyAtStartupUnderLock() async {
    final String? flat = await legacyPkamPublicKey();
    if (flat == null) {
      // A zero-length value is not a credential, and nothing must exist at
      // this key on a running server.
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
      logger.shout('The keypair of ${value.approval?.state} enrollment $id '
          'is reinstated as $primaryEnrollmentId because nothing else '
          'survives: no other approved, fully privileged enrollment without '
          'an expiry holds a key');
    }

    final EnrollDataStoreValue? primary = await primaryEnrollment();
    if (primary == null) {
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
        '$primaryEnrollmentId is untouched');
    return StartupFlatKeyOutcome.deletedAsStray;
  }

  /// The atSign's flat legacy PKAM credential, or NULL when it holds none
  /// that could authenticate anybody.
  ///
  /// PRESENT is not the bar, NON-EMPTY is. `PkamVerbHandler` refuses an empty
  /// public key before it looks at any signature, on the legacy and APKAM
  /// branches alike, so a zero-length value is a credential nobody can
  /// authenticate with and every caller here must read it exactly as it reads
  /// the key being gone. A store written by an older server can hold one even
  /// though no route here writes one.
  ///
  /// `keyStore.get` THROWS for a missing key rather than returning null, so
  /// absence has to be caught here rather than tested for.
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
  /// per-enrollment data to match [newStatus]. `skipCommit`, so enrollment
  /// records are not synced to clients.
  ///
  /// [assertedTimestamps] are timestamps the store must keep faithfully
  /// rather than rederive. A read-modify-write of an enrollment record must
  /// assert the stored `expiresAt` back, or the metadata builder recomputes
  /// it from the retained ttl and restarts the record's expiry clock at the
  /// moment of the write.
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
  /// per record. Every write bumps [cacheInvalidations], which is what stops
  /// a read that a write overtook from repopulating the cache.
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
  ///
  /// Scoped to [enId] by the `EnId` named group of
  /// `regexForPerEnrollmentNamespaces`, so a state change on one enrollment
  /// never disturbs another enrollment's per-enrollment data.
  @visibleForTesting
  Future<List<String>> movePerEnrollmentData(
    String enId, {
    required String to,
  }) =>
      movePerEnrollmentDataFor({enId}, to: to);

  /// [movePerEnrollmentData] for several enrollments in ONE pass.
  ///
  /// The pass is the cost: `getKeys` walks every key in the atSign's
  /// keystore, so one pass per enrollment makes a cascade quadratic in a
  /// quantity an attacker can inflate, a revoke of K descendants costing K+2
  /// whole-store scans. The regex exposes the owning enrollment id, so one
  /// walk can serve any number of them.
  @visibleForTesting
  Future<List<String>> movePerEnrollmentDataFor(
    Set<String> enIds, {
    required String to,
  }) async {
    if (enIds.isEmpty) return [];
    // The comparison below is against the `EnId` segment of a key the
    // KEYSTORE returned, so it is canonical. An id that is not compares
    // unequal to its own data and the move silently does nothing, leaving a
    // revoked enrollment's per-enrollment keys, its published `_apsk` among
    // them, at the APPROVED location every reader of that data goes by.
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
  ///
  /// Canonical for the same reason [buildEnrollmentKey] is: `keys:` decides
  /// whether a caller may touch a named key by comparing it against this.
  String keyForPEK(String enId) =>
      canonicalAtKey('${canonicalEnrollmentId(enId)}'
          '.${AtConstants.defaultEncryptionPrivateKey}'
          '.${EnrollmentConstants.enrollManageNamespace}'
          '$atSign');

  /// [keyForPEK]'s counterpart for the self-encryption key, canonical for the
  /// same reason.
  String keyForSEK(String enId) =>
      canonicalAtKey('${canonicalEnrollmentId(enId)}'
          '.${AtConstants.defaultSelfEncryptionKey}'
          '.${EnrollmentConstants.enrollManageNamespace}'
          '$atSign');

  /// ```
  /// public:${enVal.appName}.${enVal.deviceName}
  ///   .pkam.${EnrollmentConstants.pkamNamespace}
  ///   .__public_keys$currentAtSign
  /// ```
  /// Canonical for the same reason as [keyForPEK], and it matters more here
  /// because the components are CLIENT-CHOSEN: an app or device name carrying
  /// a capital or a space would otherwise build a key the keystore does not
  /// hold under that spelling.
  String keyForLegacyPK(EnrollDataStoreValue enVal) => canonicalAtKey('public:'
      '${enVal.appName}.${enVal.deviceName}'
      '.pkam.${EnrollmentConstants.pkamNamespace}'
      '.__public_keys$atSign');

  final RegExp ekRegex = RegExp(EnrollmentConstants.regexForEnrollmentKey);

  /// Called before *any* key in the keystore is removed.
  /// Checks if what's being removed is an enrollment and, if so,
  /// moves all per-enrollment data to [perEnrollmentDeleted]
  Future preRemoveHook(String key, {required bool skipCommit}) async {
    if (ekRegex.hasMatch(key)) {
      await _preRemove(ek: key);
    }
  }

  /// Called after *any* key in the keystore is removed. Drops the cached
  /// enrollment, if that is what went.
  ///
  /// AFTER rather than in [preRemoveHook]: the pre-hook runs while the record
  /// is still on disk and awaits several times, so anything invalidated there
  /// is reinstated by a read arriving before the delete lands.
  ///
  /// A hook rather than a line in [remove], because [remove] is not the only
  /// way an enrollment key leaves the keystore: the `delete` verb and the
  /// expired-keys sweep go straight to [AtKeyValueStore.remove], and a record
  /// left cached goes on authorising every verb its grants cover with nothing
  /// on disk to say so.
  ///
  /// The key is canonicalised because the cache is keyed by
  /// [buildEnrollmentKey], while a keystore hands its hooks the key as the
  /// caller spelled it apart from case.
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

  /// Deletes enrollment [enId]'s record, with `skipCommit` so the deletion is
  /// not written to the commit log and not synced to clients.
  ///
  /// The pre- and post-remove hooks must be active: they are what keep the
  /// rest of the enrollment's data, and the cache, consistent with the
  /// removal.
  Future<void> remove({required String enId}) async {
    if (!keyStore.preRemoveHooks.contains(preRemoveHook) ||
        !keyStore.postRemoveHooks.contains(postRemoveHook)) {
      throw StateError('Managing datastore consistency for enrollments requires'
          ' that the preRemoveHook and the postRemoveHook be active');
    }
    String ek = buildEnrollmentKey(enId);

    // Cache invalidation is [postRemoveHook]'s, which the guard above insists
    // on: this is one removal path among several, and the invariant belongs
    // where every path passes.
    await keyStore.remove(ek, skipCommit: true);
  }

  /// Every enrollment record key this atSign holds.
  ///
  /// [includeExpired] picks between two genuinely different rosters, and it is
  /// REQUIRED so that each call site states which one it means.
  ///
  ///   * `false`: the VISIBLE roster, what [AtKeyValueStore.getKeys] returns,
  ///     which omits a record whose ttl has elapsed even though the record is
  ///     still on disk.
  ///   * `true`: the STORED roster, everything the keystore holds, expiry
  ///     included. This is what [AtKeyValueStore.get] and
  ///     [AtKeyValueStore.exists] see, and it is what the atSign actually
  ///     holds.
  ///
  /// Expiry is lazy, so the two disagree until the expired-keys sweep runs.
  /// Anything deciding what the atSign IS must take the stored view, because
  /// the visible roster is one an enrollment's own key-expiry posture empties
  /// on a schedule its holder chose. Anything merely REPORTING a roster can
  /// take the visible one.
  Future<List<String>> getAllEnrollmentKeys(
      {required bool includeExpired}) async {
    if (!includeExpired) {
      return (await keyStore
              .getKeys(regex: EnrollmentConstants.enrollmentsRegex))
          .toList();
    }
    // `getKeys` has no include-expired form, so the stored roster comes off
    // `scanKeys`, which does. An unrestricted [KeyPattern] matches every key,
    // and both walks decode their keys identically, so a key enumerated here
    // is byte-identical to the one the visible roster would have returned.
    final RegExp re = RegExp(EnrollmentConstants.enrollmentsRegex);
    final List<String> keys = [];
    await for (final String key in await keyStore.scanKeys(const KeyPattern(),
        includeExpired: true)) {
      if (re.hasMatch(key)) keys.add(key);
    }
    return keys;
  }

  /// Every stored enrollment as its id and decoded value, expired records
  /// included and each reporting its state as `expired`. For the questions
  /// that have to be asked of the WHOLE roster before a write: whether a key
  /// is already held, whether an (appName, deviceName) is taken.
  ///
  /// A record swept between the listing and the read is skipped, and so is
  /// one that does not decode, with a log line. A STORE fault is not caught:
  /// swallowing it would answer "nobody holds this" about a roster that was
  /// never read, and the write the question guards would go ahead.
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
  /// Every status counts, expired-but-unswept records included: one key
  /// installed under two names is two identities with separate lifecycles,
  /// whatever state the first one is in, so a revoked or denied holder blocks
  /// re-enrolment with the same keypair until it is deleted.
  ///
  /// [excluding] is the enrollment re-sending its own current key, which is
  /// not a collision with itself. Compared by [sameApkamKeyMaterial].
  Future<(String, EnrollDataStoreValue)?> holderOfApkamPublicKey(
      String apkamPublicKey, String? signingAlgo,
      {String? excluding}) async {
    final String? excluded =
        excluding == null ? null : canonicalEnrollmentId(excluding);
    for (final (String id, EnrollDataStoreValue value)
        in await storedEnrollments()) {
      if (id == excluded) continue;
      if (sameApkamKeyMaterial(
          apkamPublicKey, signingAlgo, value.apkamPublicKey, value.signingAlgo)) {
        return (id, value);
      }
    }
    return null;
  }

  /// The bytes [publicKey] spells under [signingAlgo]: hex, in either case,
  /// for `ecc_secp256r1`, base64 for every other algorithm. Null when it does
  /// not decode as that, which a caller compares as text instead.
  ///
  /// Decoded rather than compared as text because one key has several
  /// spellings: hex decodes case-insensitively and base64 tolerates
  /// surrounding whitespace, so a uniqueness rule comparing spellings would
  /// be defeated by re-casing.
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

  /// The enrollment stored at [ek]. Throws [KeyNotFoundException] when there
  /// is none.
  ///
  /// READ-ONLY. A record whose ttl has elapsed comes back reported `expired`
  /// and is left exactly where it is. This path is taken by every verb
  /// command and every authorisation check, deliberately outside the
  /// enrollment-mutation critical section, so reaping here would be a store
  /// mutation by a reader that decided nothing, taken while a mutation of
  /// another record was in flight, and it would run the pre-remove hook's
  /// per-enrollment data movement on the authorisation path. The scheduled
  /// expired-keys sweep removes such records instead, through the same
  /// [AtKeyValueStore.remove], so the same hooks fire.
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
      // The generation the value is read AT. The store read below awaits, so
      // an enrollment write can land while it is in flight, and the value it
      // hands back is then the one from BEFORE that write; caching that
      // unconditionally reinstates a superseded record that nothing
      // invalidates again. Deliberately coarse: any enrollment write costs
      // this read its cache fill, which is cheap because enrollments are
      // written far more rarely than they are read.
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
  ///
  /// The enrollment's EFFECTIVE expiry, whatever set it last: the key-expiry
  /// posture at approval, the retrofit cap, or nothing. It lives on the
  /// record's metadata rather than in [EnrollDataStoreValue], so every
  /// projection that reports it reads it from here. A client has no other way
  /// to learn it: the record is a `__manage` key, which no enrollment may
  /// read with a data verb.
  Future<DateTime?> effectiveExpiryOf(String enrollmentKey) async =>
      (await keyStore.get(enrollmentKey))?.metaData?.expiresAt?.toUtc();

  /// The wire form of [effectiveExpiryOf]: ISO-8601 in UTC, or null.
  ///
  /// The key is emitted ALWAYS, null when there is no expiry. An absent key
  /// and a key a client failed to parse are the same thing to a careless
  /// reader; an explicit null is an answer.
  static String? expiresAtField(DateTime? expiry) =>
      expiry?.toUtc().toIso8601String();

  /// The enrollments whose keys are in [ekList], filtered to those whose
  /// status is in [statuses]. All enrollments when [ekList] is null, all
  /// statuses when [statuses] is null. Every entry carries `expiresAt`.
  ///
  /// [redactSecrets] selects the roster projection
  /// ([EnrollDataStoreValue.toJsonRoster]) instead of the full record. It is
  /// REQUIRED rather than defaulted: the full record carries the wrapped
  /// APKAM symmetric key, so every caller has to state which audience it is
  /// answering.
  Future<Map<String, Map<String, dynamic>>> getEnrollmentsAsJson(
      {required bool redactSecrets,
      List<String>? ekList,
      List<EnrollmentStatus>? statuses}) async {
    // The VISIBLE roster: this REPORTS a roster (`enroll:list`), it decides
    // nothing, and listing a record the keystore has stopped serving would
    // make the answer depend on how recently the expiry sweep ran.
    ekList ??= await getAllEnrollmentKeys(includeExpired: false);

    Map<String, Map<String, dynamic>> ejList = {};
    for (var ek in ekList) {
      EnrollDataStoreValue enVal;
      try {
        enVal = await getEnrollmentByFullKey(ek);
      } on KeyNotFoundException {
        // Deleted between the enumeration and this read; one enrollment
        // vanishing must not fail the whole roster.
        continue;
      }
      if (statuses == null ||
          statuses.contains(
              EnrollmentStatus.values.byName(enVal.approval!.state))) {
        final Map<String, dynamic> entry =
            redactSecrets ? enVal.toJsonRoster() : enVal.toJsonExtended();
        // Both projections carry the effective expiry: it says when the
        // enrollment stops authenticating and is not key material.
        entry['expiresAt'] = expiresAtField(await effectiveExpiryOf(ek));
        ejList[ek] = entry;
      }
    }
    return ejList;
  }

  /// The access [enVal] holds over [namespace], or null if it holds none.
  ///
  /// A `*` grant covers every namespace, and a grant on a parent segment
  /// covers its children (`wavi` covers `data.wavi`). That is the same rule
  /// the verb handler gates the caller on, so a caller admitted to a roster
  /// is always ON that roster.
  String? accessForNamespace(EnrollDataStoreValue enVal, String namespace) =>
      accessInNamespaces(enVal.namespaces, namespace);

  /// [accessForNamespace] over a bare grants map.
  ///
  /// Separate because a revocation event carries the grants the enrollment
  /// held rather than the enrollment itself, the record having very possibly
  /// been reaped since, so the same rule has to be askable without one.
  String? accessInNamespaces(Map<String, String> namespaces, String namespace) {
    // An EXPLICIT grant wins and the wildcard is only a fallback, which is
    // the atServer's own rule. Testing `*` inside the loop returns whichever
    // entry comes first in the stored map, and that map is insertion-ordered
    // off `jsonDecode`, so an enrollment holding both `*` and a narrower
    // grant at different access letters would report a letter the server
    // itself would not act on.
    for (final entry in namespaces.entries) {
      final ns = entry.key;
      if (ns == EnrollmentConstants.allNamespaces) continue;
      if (ns == namespace || namespace.endsWith('.$ns')) {
        return entry.value;
      }
    }
    return namespaces[EnrollmentConstants.allNamespaces];
  }

  /// The approved enrollments holding [namespace], as the flat list of maps
  /// the `enroll:listns` response carries: one entry per enrollment, shaped
  ///
  /// ```
  /// {"enrollmentId": id, "access": "r"|"rw", "apkamPubKey": pubKey,
  ///  "metadata": map|null}
  /// ```
  ///
  /// `metadata` is stored and returned opaquely.
  ///
  /// Approved only, which is what makes revocation bind a HOLDER: a revoked
  /// enrollment leaves every roster at once, on every client, including ones
  /// that never heard about the revocation.
  Future<List<Map<String, dynamic>>> getEnrollmentsForNamespace(
      String namespace) async {
    final result = <Map<String, dynamic>>[];
    // The VISIBLE roster. The two views cannot differ in the ANSWER: a record
    // the visible roster omits is one [getEnrollmentByFullKey] would report
    // `expired`, which the approved-only filter below drops either way.
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
  /// Answers `enroll:infons`. Derived from the revocation EVENTS rather than
  /// from the enrollments, which is what makes the answer survive: an
  /// enrollment record carries the APKAM key-expiry posture as its ttl, so
  /// reading the roster would let this answer vanish on a timetable chosen by
  /// whoever set that posture.
  ///
  /// An un-revoke WITHDRAWS a revocation here, because this reads the net of
  /// the events, so the value can move BACKWARDS: a client comparing it must
  /// ask whether it changed, not whether it grew. The events themselves are
  /// never rewritten.
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
      // A TIE counts as withdrawn: an un-revoke can only follow a revoke, so
      // two events on one enrollment sharing a millisecond can only be a
      // revocation and the withdrawal of it.
      if (withdrawn != null && !withdrawn.isBefore(entry.value.at)) continue;
      // Matched against the grants the enrollment held AT THE REVOCATION,
      // the only surviving record of which namespaces it took with it.
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
  /// [EnrollmentConstants.enrollmentsRegex] is an UNANCHORED substring, so a
  /// key carrying `.new.enrollments.__manage@` anywhere in it would be
  /// enumerated by [getAllEnrollmentKeys] and handed to a decoder expecting
  /// an [EnrollDataStoreValue]. It stays inside `__manage` so that scan hides
  /// it under the rule that already hides enrollment records.
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
  /// the same reason enrollment records use it: this is the atServer's own
  /// bookkeeping and has no business in a client's sync stream.
  ///
  /// No ttl, which is the point of the log and is also unbounded growth. One
  /// small record per revocation, kept for the life of the atSign, and a
  /// cascade writes one per enrollment it takes; nothing prunes them.
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
  /// past the caller: one malformed record would otherwise make
  /// `enroll:infons` permanently unanswerable for every namespace.
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
  /// deviceName.
  ///
  /// Over the STORED roster, which is what makes the repair complete. Nothing
  /// else revisits one of these keys: the pre-remove hook does not remove it,
  /// so an enrollment skipped here because its ttl had elapsed is reaped by
  /// the expiry sweep and leaves its app and device names published for the
  /// life of the atSign.
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

  /// Removes the encryption keys of enrollments that no longer exist. Called
  /// at server startup, because these keys carry no ttl of their own and so
  /// are never harvested by the expiry sweep.
  Future<List<String>> removeOrphanedApkamEncryptionKeys() async {
    final List<String> deletedOrphanedKeys = [];
    final List<String> enIds = [];
    // The STORED roster, because ORPHANED means "no record holds it" and a
    // record whose ttl has elapsed is still a record that holds it. Deciding
    // from the visible roster would delete an enrollment's encryption keys
    // while its record is still on disk, ahead of the expiry sweep, which
    // removes them itself through the pre-remove hook.
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
  /// `min(grace, what the enrollment's own key-expiry posture leaves it)`.
  ///
  /// The posture's deadline is the LATER of `createdAt + posture` and the
  /// record's stored `expiresAt`. `createdAt + posture` alone is short by the
  /// whole approval latency, since `enroll:approve` starts the posture's
  /// clock at APPROVAL; `expiresAt` alone is wrong the other way, because
  /// once a first sibling has capped the predecessor `expiresAt` IS that cap,
  /// and every later re-arm would shrink rather than extend. Taking the later
  /// is safe: both candidates are at or below `approvedAt + posture`.
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
    // A record with no stored expiry never expires, whatever posture its
    // VALUE carries, and the CRAM path writes exactly that. Folding against a
    // posture the record never had would compute a deadline in the past for
    // any root older than its stated posture, which the floor below turns
    // into a 1ms cap: the root dead instantly.
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
  /// The stranding question: whether the act about to be performed leaves the
  /// atSign able to restore a root INDEFINITELY. Any expiry disqualifies a
  /// candidate, however distant, because an atSign that can restore a root
  /// only until some date loses that afterwards with nothing at the time of
  /// the act to say so.
  ///
  /// ⚠️ [excluding] is a SET because a revoke CASCADES, and the records a
  /// cascade is about to take are still `approved` on disk while this runs:
  /// counting one that is leaving reports the atSign safe at the moment its
  /// last usable root is taken away.
  ///
  /// Roots are counted by [isUsableRootEnrollment], so a fully privileged
  /// record with an empty public key does not count. Full privilege rather
  /// than the ability to approve, because approving is checked per namespace
  /// against what the approver holds, so an enrollment with `__manage` but
  /// not `*` can never admit one carrying `*`.
  ///
  /// Asked of the enrollment ROSTER and of nothing else. The flat legacy
  /// credential is migrated into the `primary` enrollment before any client
  /// connects, so the roster holds everything the atSign can authenticate
  /// as.
  Future<bool> hasUnexpiringRootEnrollment(Set<String> excluding) async {
    final excludedKeys = excluding.map(buildEnrollmentKey).toSet();
    // The STORED roster. A stranding decision is a question about what the
    // atSign HOLDS, and answering it from a roster that thins on a timer is
    // how the same act becomes safe or unsafe according to when the sweep
    // last ran.
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
      final AtData? record = await keyStore.get(ek);
      if (record?.metaData?.expiresAt == null) return true;
    }
    return false;
  }

  /// Whether [value] is a root the atSign could fall back on: fully
  /// privileged AND with a non-empty public key recorded for it.
  ///
  /// THAT IS THE WHOLE BAR, and it is the bar authentication applies before
  /// it looks at a signature: `PkamVerbHandler` refuses an empty public key
  /// on the legacy and APKAM branches alike, so an empty value and a missing
  /// one are the same credential, none. `enroll:request` writes whatever
  /// `apkamPublicKey` it was sent, so zero-length is reachable.
  ///
  /// Applied on both sides of every stranding decision, what an act REMOVES
  /// and what SURVIVES it, so that "root" means one thing in both.
  ///
  /// ⚠️ It does NOT establish that anybody holds the private half: "usable"
  /// means a signature could be CHECKED against this record, not that one
  /// could be produced for it. Possession is demanded where the key is
  /// WRITTEN, by `enroll:update`, which refuses a new `apkamPublicKey`
  /// without a signature by the private half being installed;
  /// `enroll:request` demands no such proof, so possession of an approved but
  /// never used enrollment's key is proved only at its first `pkam:`.
  ///
  /// [enrollmentId] is for the caller's reporting; the verdict is a property
  /// of [value] alone. This is NOT the question `isRootPrivilegedConnection`
  /// asks: that one decides what an already-authenticated connection may do.
  bool isUsableRootEnrollment(
      String enrollmentId, EnrollDataStoreValue value) {
    if (!value.isRootEnrollment) return false;
    return value.apkamPublicKey.isNotEmpty;
  }

  /// Which of [enrollmentIds] are usable roots ([isUsableRootEnrollment]) and
  /// currently approved, that is, which of them a revoke of that set would
  /// actually take away.
  ///
  /// The companion to [hasUnexpiringRootEnrollment]: that one asks what
  /// SURVIVES an act, this one what the act REMOVES, and a refusal built on
  /// either alone is wrong. Asking only what survives refuses every revoke on
  /// an atSign whose last root is short-lived, even ones touching no root;
  /// asking only what is removed refuses a revoke that leaves a good root
  /// behind.
  ///
  /// APPROVED is the same condition [revokeAll] applies, so the answer
  /// describes exactly the records the cascade will rewrite.
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

  /// The enrollment that APPROVED [id], read straight off the stored record.
  ///
  /// Not the enrollment [id] replaced. A retrofit produces a PEER, the same
  /// principal re-keyed, so its successor inherits this value from its
  /// predecessor rather than naming it, and revocation does not travel the
  /// replacement edge at all.
  ///
  /// Deliberately NOT via [getEnrollmentByFullKey]: `keyStore.get` returns a
  /// record whose ttl has elapsed, which is what lets the walk cross an
  /// expired link. ⚠️ Only until the expired-keys sweep runs, after which
  /// this read throws like any other absent key, so crossing an expired link
  /// is a window rather than a property. See [descendantsOf].
  Future<String?> _approverIdOf(String id, Map<String, String?> memo) async {
    if (memo.containsKey(id)) return memo[id];
    String? approverId;
    try {
      final AtData? record = await keyStore.get(buildEnrollmentKey(id));
      final String? raw = record?.data;
      if (raw != null) {
        approverId = EnrollDataStoreValue.fromJson(jsonDecode(raw))
            .parentEnrollmentId;
      }
    } on KeyNotFoundException {
      // Genuinely absent: this chain ends here and no other.
      approverId = null;
    } on FormatException catch (e) {
      // Present but undecodable. Same outcome, but it is not routine.
      logger.severe('Enrollment $id does not decode; treating it as the end '
          'of the chain it is in: $e');
      approverId = null;
    }
    // A STORE fault is deliberately NOT caught. Swallowing it would end the
    // chain silently, drop every enrollment behind this link out of the
    // cascade and let the verb report success on a partial revocation, and
    // the memo would then serve that answer to every other candidate whose
    // chain runs through this id.
    memo[id] = approverId;
    return approverId;
  }

  /// Every enrollment that reaches [enrollmentId] by following approver links
  /// upward, to any depth. Never contains [enrollmentId].
  ///
  /// Walked UPWARD from each candidate rather than downward from the target,
  /// and every status is followed. A downward walk has to ENUMERATE the
  /// intermediate links to learn their edges, and key enumeration hides
  /// records whose ttl has elapsed, so an expired enrollment part-way down a
  /// chain would take its edge with it and everything behind it would survive
  /// the cascade. Upward, only the candidates are enumerated and each link is
  /// fetched by key, which returns expired records.
  ///
  /// ⚠️ A SEVERED link still orphans everything behind it, because nothing
  /// records ancestry beyond an enrollment's immediate approver: a revoke
  /// reaches the first live candidate and stops. `enroll:delete` on a middle
  /// link severs one, and so does the expired-keys sweep removing a middle
  /// link whose ttl is shorter than those behind it. Closing that needs
  /// ancestry that outlives the record, which this does not have.
  ///
  /// ⚠️ The APPROVAL edge only. The replacement edge
  /// ([EnrollDataStoreValue.retrofitPredecessorEnrollmentId]) is not walked:
  /// a retrofit produces a peer, so revoking a superseded credential must not
  /// take the one that superseded it. A successor is reached through the
  /// approver it INHERITS from its predecessor, which is what stops a
  /// retrofit being an escape hatch.
  Future<Set<String>> descendantsOf(String enrollmentId) async {
    // Canonical, because every id this is compared against comes out of a
    // keystore key or out of a stored approver link written from one. A
    // non-canonical target matches nothing and the walk returns EMPTY, which
    // reads exactly like an enrollment with no descendants, so a cascade that
    // swept nothing would report success.
    enrollmentId = canonicalEnrollmentId(enrollmentId);
    final Set<String> found = {};
    final Map<String, String?> memo = {};
    // The STORED roster, so that every status really is followed. The climb
    // reads through an elapsed record because [_approverIdOf] fetches by key;
    // a visible-roster enumeration here would leave an enrollment whose ttl
    // had elapsed outside the cascade while its record, and its published
    // `_apsk` at the approved address, were still there.
    for (final ek in await getAllEnrollmentKeys(includeExpired: true)) {
      final String candidate = getIdFromKey(ek);
      if (candidate == enrollmentId) continue;
      // `seen` terminates the climb. The enroll verb cannot build a cycle,
      // but a walk over stored data should not rely on that to terminate.
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

  /// Moves every enrollment [predecessorId] approved onto [successorId].
  ///
  /// The cap puts a deadline on the predecessor, and nothing records ancestry
  /// beyond an enrollment's immediate approver, so without this the capped
  /// approver's expiry would sever the chain and orphan everything behind it
  /// (see [descendantsOf]). The successor is where those enrollments belong:
  /// it is the same principal re-keyed and already INHERITS the predecessor's
  /// approver. It is never moved onto itself, which would be a cycle in
  /// stored data.
  ///
  /// Runs INSIDE [serialiseMutation]; its caller holds the section. Every
  /// child is a read-modify-write of a whole record, and losing that update
  /// is PERMANENT and silent because nothing ever re-parents twice. The WHOLE
  /// loop is in the section rather than a re-read per child, which would
  /// narrow the window without closing it.
  Future<void> _adoptApprovalChildren(
      String predecessorId, String successorId) async {
    // The STORED roster. This pass's omissions are PERMANENT, because nothing
    // ever re-parents twice, so a child missed here names a predecessor for
    // the rest of its life and sits outside every later revocation cascade.
    // The sharp case is a record the visible roster omits for a ttb it has
    // not reached: it is not expiring, it is not yet BORN, and it outlives
    // this pass.
    for (final ek in await getAllEnrollmentKeys(includeExpired: true)) {
      final String childId = getIdFromKey(ek);
      if (childId == successorId) continue;
      final AtData? record = await keyStore.get(ek);
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
      if (child.parentEnrollmentId != predecessorId) continue;

      final EnrollmentStatus? status =
          EnrollmentStatus.values.asNameMap()[child.approval?.state ?? ''];
      if (status == null) {
        logger.warning('Not re-parenting $childId onto $successorId: its '
            'approval state ${child.approval?.state} is unreadable');
        continue;
      }

      child.parentEnrollmentId = successorId;
      record.data = jsonEncode(child.toJson());
      // The child's own expiry must not move: a plain write re-derives it
      // from the retained ttl and would restart its clock at this moment.
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
  /// Anything not currently approved is skipped rather than rewritten: a
  /// pending enrollment has no credential to strip until it is approved, and
  /// a denied or revoked one is not made "more revoked" by writing it again.
  /// Each write asserts the stored expiry back, and the per-enrollment data
  /// move is made ONCE for the whole set.
  ///
  /// [byEnrollmentId] is the enrollment on the connection that issued the
  /// command, null for a CRAM connection, which carries none; [cascadedFrom]
  /// is the enrollment it NAMED. Both go on every event, because an
  /// enrollment revoked by a cascade was revoked for a reason not visible
  /// from its own record.
  ///
  /// [at] is the moment of the COMMAND, passed in so that every enrollment
  /// the one act revoked carries one timestamp; per-write stamps would invite
  /// a reader to order them as separate decisions.
  Future<List<String>> revokeAll(Iterable<String> enrollmentIds,
      {required String? byEnrollmentId,
      required String cascadedFrom,
      required DateTime at}) async {
    final List<String> revoked = [];
    // The grants each one held, captured before the write, because the event
    // outlives the record they are stored on.
    final Map<String, Map<String, String>> grantsHeld = {};
    // Prepared first, written second, so the per-enrollment data move can be
    // made ONCE for the whole cascade. `put` per descendant costs a
    // whole-keystore walk each, K+2 scans for a cascade of K, on a path whose
    // K is inflatable by minting successors.
    final Map<String, AtData> pending = {};
    for (final id in enrollmentIds) {
      final ek = buildEnrollmentKey(id);
      // `get` THROWS on an absent key rather than returning null, so without
      // this a descendant deleted or reaped between the walk and this loop
      // aborts the whole verb, leaving the enrollments already revoked with
      // their connections still open.
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

    // The history goes in BEFORE the records change: a crash between the two
    // then leaves an event describing a revocation that did not land, which
    // costs a client a refetch, whereas the other order loses the fact
    // entirely and tells a client nothing changed when something did.
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
    // `put` would repeat the pass per record, and the move is the expensive
    // half.
    await movePerEnrollmentDataFor(revoked.toSet(),
        to: EnrollmentConstants.perEnrollmentRevoked);
    for (final id in revoked) {
      final AtData atData = pending[id]!;
      // The stored expiry is asserted back on each write. A revoke says
      // nothing about expiry, and the metadata builder re-derives
      // `expiresAt = now + ttl` on any write that does not assert it, so a
      // cascade would otherwise hand every enrollment it revoked a fresh full
      // lifetime and restart any retrofit cap on them.
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
  /// Read immediately before the write, for the same reason the stamp itself
  /// is: everything in between awaits, and a snapshot from before all of it
  /// would revert a change made since. Called from inside
  /// [serialiseMutation], so no other enrollment mutation can be that change.
  /// Best-effort: if it fails the successor stays stamped.
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
  /// Re-applied every time a successor ARMS, and computed fresh from the
  /// predecessor's own posture rather than folded into a previously written
  /// cap: sibling clones of one keyfile upgrade whenever each device next
  /// runs, so a deadline fixed by the first sibling's upgrade would strand
  /// every laggard whose next run falls outside that window.
  ///
  /// The ttl is written as-is, because the store anchors it at the write
  /// (`expiresAt = now + ttl`), and it is computed HERE against the record
  /// just read rather than taken from the caller, whose value would be
  /// stamped as the deadline it checked PLUS however long its keystore walk
  /// took.
  Future<RetrofitCapOutcome> capEnrollmentExpiry(String enrollmentId) async {
    final key = buildEnrollmentKey(enrollmentId);
    final AtData? atData;
    try {
      atData = await keyStore.get(key);
    } on KeyNotFoundException {
      return RetrofitCapOutcome.predecessorGone;
    }
    if (atData == null) return RetrofitCapOutcome.predecessorGone;

    // The status comes off the record JUST READ, never off a caller's
    // snapshot. `put` moves an enrollment's per-enrollment data to match the
    // status it is handed, so a stale status is not a cosmetic mismatch: a
    // revoke landing while the caller walked the keystore would be UNDONE,
    // the data moved back to the approved location, republishing the `_apsk`
    // a revocation had just parked.
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
    // written back at all: capping only ever SHORTENS the life of a working
    // credential.
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
  /// the successor's first authentication: the successor is stamped as having
  /// settled it, the predecessor's approval children move onto the successor,
  /// and a predecessor that is not fully privileged is capped. A no-op for an
  /// enrollment that replaced nothing, which is every enrollment except a
  /// retrofit's successor.
  ///
  /// Settled at an authentication rather than where the successor is stored,
  /// because storing it proves only that the SERVER wrote a record: the
  /// successor's APKAM private half is persisted client-side, and a keyfile
  /// write that fails leaves the successor existing nowhere else while a
  /// clock runs on the predecessor, by then the only credential that works.
  /// Only the FIRST authentication settles, or every reconnect would rewrite
  /// a full grace period and the predecessor would never retire.
  ///
  /// WHICH PREDECESSORS ARE CAPPED. One holding `*:rw` and `__manage:rw`
  /// keeps its life, because a clock on an atSign's root is a clock on its
  /// ability to restore itself. Every other predecessor is capped to
  /// `min(grace, what its own key-expiry posture leaves it)` and can never be
  /// the last root, so no stranding question is asked of it. A predecessor
  /// that is NOT APPROVED stops everything and leaves the successor
  /// unstamped: it is already retired, writing it back would hand it a fresh
  /// ttl, and an un-revoke can restore it, so the question is re-asked at the
  /// next authentication rather than frozen into the record.
  ///
  /// The decide-and-write half runs under [serialiseMutation]: the adoption's
  /// lost update would be permanent, and the stamp is a whole-record write a
  /// concurrent revoke would overwrite. The EARLY EXITS are outside it
  /// deliberately, since this runs on every APKAM authentication and
  /// everything but a retrofit's successor leaves at them; neither test
  /// writes, and both are re-made inside the section.
  ///
  /// Never throws: an authentication has already succeeded by this point, and
  /// refusing one because bookkeeping failed would be an outage.
  Future<void> armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
    try {
      // Through the cached read: the PKAM path has just read this same
      // enrollment, so it is warm. Replaced nothing, or already settled: the
      // exit almost every authentication takes.
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
      // Re-asked inside the critical section. The same two tests ran outside
      // it so that a plain authentication never takes the lock, and either
      // can have changed while this call waited: another successor's arming,
      // or a revoke, is exactly what it waited behind.
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

      // Whether this authentication settles the predecessor (stamps the
      // successor and moves the predecessor's children), and whether the
      // predecessor is capped on the way.
      bool settled = false;
      bool capPredecessor = false;
      final bool predecessorGone = predecessor == null;

      if (predecessorGone) {
        // Nothing can bring the predecessor back. Its children are orphans
        // already, and the successor is what they should hang off.
        settled = true;
      } else if (predecessor.approval?.state != EnrollmentStatus.approved.name) {
        // Not settled and not capped: a denied, revoked or expired
        // predecessor is already retired, and writing it back would give it a
        // fresh ttl. Left unstamped deliberately, because an un-revoke
        // restores it and a transient state must not become a permanent
        // exemption.
        logger.info('Enrollment $successorEnrollmentId replaced $predecessorId, '
            'which is ${predecessor.approval?.state} — not capping it');
      } else if (predecessor.isRootEnrollment) {
        // A fully privileged predecessor keeps its life. Its children still
        // move: the successor is the same principal re-keyed and stands where
        // the predecessor stood, whatever clock it is or is not on.
        logger.info('Enrollment $successorEnrollmentId replaced $predecessorId, '
            'which holds full privilege and keeps its life; what it admitted '
            'now hangs off its successor');
        settled = true;
      } else {
        settled = true;
        capPredecessor = true;
      }

      if (!settled) return;

      // Read immediately before the write, so the record written here is the
      // one the section is working from rather than a snapshot taken before
      // the predecessor lookup and the keystore walk above. The critical
      // section is what closes the lost update; the keystore has no
      // compare-and-set to close it with.
      final AtData? atData = await keyStore.get(key);
      final String? raw = atData?.data;
      if (atData == null || raw == null) return;
      final successor = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      // `put` invalidates the cache only after its own await, so a concurrent
      // READER, which the critical section does not serialise, can repopulate
      // it with a pre-write value. This uncached re-test is what makes
      // "first" hold; the cached checks at the entry point are a fast path.
      if (successor.predecessorCapArmedAt != null) return;

      successor.predecessorCapArmedAt = DateTime.now().toUtc();
      atData.data = jsonEncode(successor.toJson());
      // The successor's OWN expiry must not move. A plain write re-derives
      // `expiresAt` from the retained ttl and would restart its clock at this
      // moment, extending the credential by however long it waited to
      // authenticate; asserting the stored absolute suppresses that. A null
      // `expiresAt` is a record that never expires, and asserting nothing
      // leaves it that way.
      final storedExpiry = atData.metaData?.expiresAt;
      // The record's OWN status, never a default. `put` moves an
      // enrollment's per-enrollment data to match the status it is handed, so
      // defaulting to `approved` would relocate the data of a record whose
      // state could not be read. An unparseable status cannot reach a
      // successful PKAM, so refusing to write is the only safe move if it
      // ever fires.
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

      // The cap goes AFTER the stamp. A write failing between the two leaves
      // the successor recorded as processed and the predecessor keeping the
      // expiry it had, which only slows the migration. The other order fails
      // far worse: a capped predecessor with no stamp is re-capped with a
      // fresh full grace on every later authentication, so it never retires.
      if (capPredecessor) {
        final RetrofitCapOutcome outcome =
            await capEnrollmentExpiry(predecessorId);
        // That ordering means a cap declining at the write leaves a durable
        // stamp claiming the question is settled when the reason it was not
        // was transient: the predecessor was approved when the decision was
        // taken and revoked by the time of the write, so an un-revoke would
        // restore it with no expiry and no successor able to re-arm, forever.
        // The stamp is taken back ONLY for that outcome, and the predecessor
        // is live, so its children stay where they are.
        if (outcome == RetrofitCapOutcome.notApproved ||
            outcome == RetrofitCapOutcome.unreadable) {
          await _clearCapStamp(successorEnrollmentId, key);
          return;
        }
      }
      // The children move whenever the stamp stands: off a capped
      // predecessor, off a root that keeps its life, and off one already
      // gone.
      await _adoptApprovalChildren(predecessorId, successorEnrollmentId);
    } catch (e) {
      logger.warning('Could not arm the retrofit cap for '
          '$successorEnrollmentId: $e');
    }
  }
}

/// What [EnrollmentManager.migrateFlatKeyAtStartup] found the flat legacy
/// credential to be, and did about it.
enum StartupFlatKeyOutcome {
  /// No flat key was stored.
  none,

  /// A copy of an approved or revoked root's key, with another unexpiring
  /// root surviving: deleted.
  deletedAsCopyOfRoot,

  /// Minted `primary` from it, then deleted it.
  migratedIntoPrimary,

  /// `primary` already held it, a migration that did not finish: deleted.
  deletedAsResidue,

  /// `primary` holds a different key: deleted and logged, `primary` untouched.
  deletedAsStray,
}
