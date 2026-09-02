import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_revocation_event.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';
import 'package:mutex/mutex.dart';
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

  /// Serialises [armRetrofitCapOnFirstAuth] against itself.
  ///
  /// The decision it takes is read-modify-write over the WHOLE keystore: it
  /// asks whether any unexpiring root would survive capping this predecessor,
  /// and then caps. Two successors authenticating at once each ran that walk
  /// before either wrote, so each saw the other's root still uncapped, each
  /// concluded it was safe, and both roots were capped — leaving the atSign
  /// with no root it could restore itself from. Two devices reconnecting
  /// together is enough; the re-read before the write narrows the lost update
  /// on the successor's own record and never re-takes the decision.
  ///
  /// One instance per atSign, built once by `AtSecondaryServerImpl`, so an
  /// instance field is the whole of the contention.
  final Mutex _capArmingLock = Mutex();

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

  /// The enrollment id of the HOUSEKEEPING enrollment — the record that gives
  /// the atSign's legacy PKAM credential an identity.
  ///
  /// The legacy keyfile authenticates with no enrollment id at all, so it has
  /// never had an enrollment record: nothing states its grants, nothing can
  /// revoke it, and nothing ever retires it. This record is what a legacy
  /// connection authenticates AS, so that credential gets the lifecycle every
  /// other credential already has.
  ///
  /// The id is the literal `primary` rather than a generated one, and that is
  /// load-bearing twice over. It is deterministic, so finding the record is a
  /// single key read and create-if-absent costs nothing — no scan of the
  /// keystore, and no new at-rest field to tag it with. And `primary` is
  /// ALREADY the atSign-wide sentinel for "no enrollment id":
  /// `abstract_update_verb_handler` substitutes it into its authorisation
  /// message, and a client with no enrollment publishes its signing key at
  /// `public:_apsk.primary.a.__e@<atSign>`. That published key therefore
  /// becomes this enrollment's per-enrollment data as soon as the record
  /// exists, so revoking or expiring the legacy credential parks its signing
  /// key exactly as it does for any other enrollment. Nothing retires it
  /// today.
  static const String housekeepingEnrollmentId = 'primary';

  /// The housekeeping enrollment, creating it if this atSign has none.
  ///
  /// Called on every legacy PKAM authentication, so the already-created case
  /// is one key read and no write.
  ///
  /// The record holds NO credential of its own: `apkamPublicKey` is stored
  /// EMPTY, and that is the point of it rather than an omission. Legacy PKAM
  /// verifies against the LIVE `at_pkam_publickey` in the keystore and never
  /// against this record, so a copy here is read by nothing and can only go
  /// stale — one credential with two at-rest spellings that nothing keeps in
  /// step, where every divergence is either a stranding or an authentication
  /// against a key the atSign has replaced.
  ///
  /// Empty is also what makes APKAM-as-`primary` impossible BY CONSTRUCTION.
  /// An APKAM authentication takes the public key off the record and refuses
  /// an absent or empty one before any signature is looked at, so there is no
  /// key for such a signature to verify against however the id reaches the
  /// lookup. The identifier comparison that also refuses it is exact, while
  /// the keystore folds ids on the way in — it trims, lowercases and strips
  /// spaces — so a spelling that resolves to this very record can compare
  /// unequal to the literal id. The empty key does not care how the id was
  /// spelled.
  ///
  /// An existing record is returned exactly as stored, whatever its status.
  /// Re-approving a revoked housekeeping enrollment here would make legacy
  /// authentication a way to undo its own revocation.
  ///
  /// Created `approved`, fully privileged, and with no expiry — it stands for
  /// the credential the atSign was onboarded with. It carries NO approver: no
  /// enrollment admitted it, the server created it for itself, so no
  /// revocation cascade can reach it. That is deliberate rather than an
  /// oversight — a cascade able to sweep it away would strand the very
  /// credential it exists to govern.
  ///
  /// Two legacy connections authenticating at once may both find it absent and
  /// both write it. They write identical content, so the race is benign.
  ///
  /// Returns NULL when the record is absent and must not be created. The
  /// caller must refuse the authentication rather than treat it as a
  /// bootstrap. Two states reach it, and neither is a bootstrap:
  ///
  ///   * there is no usable legacy key — the credential has been RETIRED,
  ///     because removing this record always takes the key with it;
  ///   * the legacy key is some enrollment's own `apkamPublicKey` — it is a
  ///     COPY of that enrollment's credential rather than a legacy one, and
  ///     minting an identity for it is the dual-identity bug this record
  ///     exists to end.
  Future<EnrollDataStoreValue?> ensureHousekeepingEnrollment() async {
    try {
      return await getEnrollmentById(housekeepingEnrollmentId);
    } on KeyNotFoundException {
      // Absent — but absent says nothing on its own, and this is the
      // distinction the whole retirement path rests on.
    }

    // Whether absence means "never existed" or "already retired" is decided by
    // re-reading the legacy key, because removing this record ALWAYS takes
    // `at_pkam_publickey` with it. Key still usable => the record never
    // existed and this is a bootstrap. Key gone => it was retired, and
    // re-creating it would resurrect a credential the atSign has finished
    // with, indefinitely.
    //
    // The read is deliberately made HERE rather than taken from the caller.
    // Retirement happens through this method: reading an expired enrollment
    // removes it, and the pre-remove hook deletes the legacy key in the same
    // breath — so a key the caller read moments ago, to verify the signature,
    // may already be gone by the time we get here. Re-reading is what closes
    // that window rather than widening it.
    final String? legacyKey = await legacyPkamPublicKey();
    if (legacyKey == null) {
      logger.info('Not creating the housekeeping enrollment: '
          '${AtConstants.atPkamPublicKey} is absent or empty, so there is no '
          'credential for the record to stand for');
      return null;
    }

    // A LEGACY credential is one no enrollment holds. A value that is some
    // enrollment's own `apkamPublicKey` is a copy of that enrollment's
    // credential — older servers' CRAM auto-approve branch wrote the enrolling
    // app's key here "for old clients" — and minting `primary` from it would
    // give one keypair a second identity with a lifecycle of its own. That is
    // the dual-identity bug itself: revoking the app's enrollment would leave
    // its own keypair authenticating as `primary`, fully privileged and
    // permanent, with nothing left able to withdraw it.
    //
    // Declining is a REFUSAL, not a repair. Nothing here deletes the key: this
    // server cannot tell such a copy from a credential an owner provisioned on
    // purpose with a keypair it also enrolled, so removing one would lock out
    // an owner rather than tidy up an app. The atSign is left exactly as it
    // was, with legacy authentication refused, and an operator who meant the
    // key to be legacy can rotate it to a keypair no enrollment holds with
    // `update:privatekey:at_pkam_publickey <new public key>` over an owner
    // connection.
    final List<String> holders =
        await enrollmentsHoldingApkamPublicKey(legacyKey);
    if (holders.isNotEmpty) {
      logger.warning('Not creating the housekeeping enrollment: '
          '${AtConstants.atPkamPublicKey} is the apkamPublicKey of '
          'enrollment(s) ${holders.join(', ')}, so it is a copy of an '
          'enrollment\'s own credential rather than a legacy one. Legacy '
          'authentication is refused rather than granting that keypair a '
          'second, separately governed identity');
      return null;
    }

    // EMPTY, never a snapshot of the key just read. See the doc comment: the
    // record is an identity for the legacy credential, not a second copy of
    // it, and an empty key is what makes an APKAM authentication naming this
    // enrollment fail closed at the verifier's own emptiness guard.
    final EnrollDataStoreValue value = EnrollDataStoreValue(
      Uuid().v4(),
      'legacy',
      'legacy',
      '',
    )
      ..namespaces = {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      }
      ..approval = EnrollApproval(EnrollmentStatus.approved.name);

    logger.info('Creating the housekeeping enrollment '
        '$housekeepingEnrollmentId for this atSign\'s legacy PKAM credential');
    await put(
      housekeepingEnrollmentId,
      AtData()..data = jsonEncode(value.toJson()),
      EnrollmentStatus.approved,
    );
    return value;
  }

  /// The atSign's legacy PKAM credential, or NULL when it holds none that
  /// could authenticate anybody.
  ///
  /// PRESENT is not the bar, NON-EMPTY is. The server refuses an empty public
  /// key before it looks at any signature — `PkamVerbHandler`'s
  /// `publicKey.isEmpty` guard, which covers the legacy and APKAM branches
  /// alike — so a zero-length value is a credential nobody can authenticate
  /// with, and every caller here must read it exactly as it reads the key
  /// being gone. Anything else lets a record stand over a key that cannot
  /// work, which is the phantom [hasUnexpiringRootEnrollment] refuses to
  /// count.
  ///
  /// Zero-length is a state the atSign can genuinely be found in: the `update`
  /// grammar demands a non-empty value, but `update:json` carries the value
  /// inside the JSON document instead, so an owner connection can store one.
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

  /// The ids of every stored enrollment whose own APKAM credential is
  /// [apkamPublicKey].
  ///
  /// Read straight through the keystore rather than through
  /// [getEnrollmentByFullKey], which treats an elapsed ttl as a reason to
  /// DELETE the record. Callers are deciding whether to REFUSE something and
  /// have not decided to write anything, so reaping enrollments here would
  /// turn a question into a mutation.
  ///
  /// EVERY status is compared, revoked included, and that is the case the
  /// answer exists for: a key that goes on authenticating after the enrollment
  /// holding it was revoked is the whole hazard, so filtering by status would
  /// look past exactly the record being asked about.
  ///
  /// An empty [apkamPublicKey] matches nothing. The housekeeping enrollment
  /// stores an empty key deliberately, so an emptiness that matched would
  /// report every credential-less record as a holder of every other one.
  Future<List<String>> enrollmentsHoldingApkamPublicKey(
      String apkamPublicKey) async {
    if (apkamPublicKey.isEmpty) return const [];
    final List<String> holders = [];
    for (final ek in await getAllEnrollmentKeys()) {
      final AtData? record;
      try {
        record = await keyStore.get(ek);
      } on KeyNotFoundException {
        continue; // removed between the enumeration and this read
      }
      final String? raw = record?.data;
      if (raw == null) continue;
      final EnrollDataStoreValue value;
      try {
        value = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      } catch (e) {
        logger.severe('Could not decode enrollment ${getIdFromKey(ek)} while '
            'looking for the holders of an APKAM public key: $e');
        continue;
      }
      if (value.apkamPublicKey == apkamPublicKey) {
        holders.add(getIdFromKey(ek));
      }
    }
    return holders;
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

    // The housekeeping enrollment going takes the legacy PKAM public key with
    // it, and that is the whole of what makes the legacy credential
    // retirable: the key is what legacy authentication verifies against, so
    // removing it is removing the credential. This hook is the only path that
    // removes this record — not because it is a protected key, which it is
    // not in any way that bites, but because the delete verb refuses
    // `privatekey:` keys on GRAMMAR.
    //
    // Deliberately WITHOUT a discriminator. Both ways the record can go
    // should take the key with it — expiry, once a retrofit's successor has
    // proved itself, and `enroll:delete` on a revoked one — so the fact that
    // this hook cannot tell those apart stops mattering.
    //
    // It is also what lets absence be read: with the key always going at the
    // same moment, a missing record plus a present key can only mean the
    // record never existed, which is how a bootstrap is told from a
    // retirement.
    if (enId == housekeepingEnrollmentId) {
      if (await keyStore.exists(AtConstants.atPkamPublicKey)) {
        logger.warning('_preRemove: retiring the legacy PKAM credential — '
            'removing ${AtConstants.atPkamPublicKey} with the housekeeping '
            'enrollment');
        await keyStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);
      } else {
        logger.info('_preRemove: ${AtConstants.atPkamPublicKey} has already '
            'been removed');
      }
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

  /// Whether any enrollment outside [excluding] is an APPROVED root that will
  /// NOT expire — `rw` on both `*` and `__manage`, and no expiry at all.
  ///
  /// The precise question behind sparing a predecessor, and behind refusing a
  /// self-revocation: not "is this the atSign's first enrollment", nor "does
  /// the successor outlive it", but whether the act about to be performed
  /// leaves the atSign able to restore a root INDEFINITELY.
  ///
  /// A candidate with any expiry does not count, however distant (gkc,
  /// 2026-09-01). It was previously enough to outlive a deadline computed from
  /// the caller's own record, and that only defers the stranding: the atSign
  /// keeps the ability to restore a root until that date and loses it
  /// afterwards, with nothing at the time of the revoke to say so. Comparing
  /// one record's expiry against another's also made the answer depend on who
  /// was asking, so the same atSign was safe or stranded according to which
  /// credential ran the verb.
  ///
  /// ⚠️ APPROVED is load-bearing, not incidental. The housekeeping enrollment
  /// is a permanent root and would otherwise satisfy this on every atSign
  /// forever — but it can be REVOKED like any other, and a revoked one must
  /// stop counting the moment it is. Counting it would report the atSign safe
  /// at exactly the moment its last usable root was taken away.
  ///
  /// Full privilege rather than the ability to approve, because approving is
  /// checked per namespace against what the approver itself holds — `__manage`
  /// included, so an approver holding `__manage:r` confers no more than
  /// `__manage:r`. An enrollment with `__manage` but not `*` can admit new
  /// enrollments and can never admit one carrying `*`, so it keeps an atSign
  /// running without being able to give it a root back.
  ///
  /// ⚠️ The housekeeping enrollment counts only while `at_pkam_publickey` is
  /// still in the keystore AND NON-EMPTY. Alone among enrollments it holds no
  /// credential of its own — it is an identity for the legacy keyfile, and the
  /// keyfile authenticates against that key — so a record standing over a key
  /// nobody can authenticate with is a PHANTOM root: fully privileged,
  /// approved, permanent, and impossible to authenticate as. Counting it
  /// answers "the atSign can restore a root" with a record nobody holds a
  /// credential for, which is the same stranding this method exists to refuse,
  /// arrived at from the other direction. Every other enrollment carries its
  /// own key in the record, so record and credential cannot come apart for
  /// them.
  ///
  /// PRESENCE is not the bar because it is not the bar anywhere else either:
  /// authentication refuses an empty public key before it looks at a
  /// signature, so an empty value and a missing one are the same credential —
  /// none. See [legacyPkamPublicKey], which is also where the ways an empty
  /// one gets written are recorded.
  ///
  /// [excluding] is a SET rather than a single id because a revoke CASCADES.
  /// The enrollments a cascade is about to revoke are still `approved` in the
  /// keystore while this runs, so asking the question without them would count
  /// the very enrollments the act is about to remove — and report the atSign
  /// safe at the moment it is being stranded.
  Future<bool> hasUnexpiringRootEnrollment(Set<String> excluding) async {
    final excludedKeys = excluding.map(buildEnrollmentKey).toSet();
    final String housekeepingKey =
        buildEnrollmentKey(housekeepingEnrollmentId);
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
      if (ek == housekeepingKey && await legacyPkamPublicKey() == null) {
        continue;
      }
      final AtData? record = await keyStore.get(ek);
      if (record?.metaData?.expiresAt == null) return true;
    }
    return false;
  }

  /// Which of [enrollmentIds] are fully privileged AND currently approved —
  /// that is, which of them a revoke of that set would actually take away.
  ///
  /// The companion question to [hasUnexpiringRootEnrollment]: that one asks
  /// what SURVIVES an act, this one asks what the act REMOVES. Both are
  /// needed, because a refusal built on either alone is wrong. Asking only
  /// what survives refuses every revoke on an atSign whose last root is
  /// short-lived, including ones that touch no root at all; asking only what
  /// is removed refuses a revoke that leaves a perfectly good root behind.
  ///
  /// APPROVED is the same condition [revokeAll] applies, so the answer
  /// describes exactly the records the cascade will rewrite: an enrollment
  /// already revoked or denied is not taken away again, and a pending one is
  /// left alone, so neither can be lost by an act that names it.
  ///
  /// Read through the keystore rather than [getEnrollmentByFullKey], which
  /// treats an elapsed ttl as a reason to DELETE the record. A decision about
  /// whether an act would strand the atSign is the worst possible moment to
  /// reap enrollments, and the caller has not yet decided to write anything.
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
      if (value.isRootEnrollment) roots.add(id);
    }
    return roots;
  }

  /// The enrollment that APPROVED [id], read straight off the stored record.
  ///
  /// Not the enrollment [id] replaced. A retrofit produces a PEER — the same
  /// principal re-keyed — so its successor inherits this value from its
  /// predecessor rather than naming it, and revocation therefore does not
  /// travel the replacement edge at all.
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
  Future<String?> _approverIdOf(String id, Map<String, String?> memo) async {
    if (memo.containsKey(id)) return memo[id];
    String? approverId;
    try {
      final AtData? record = await keyStore.get(buildEnrollmentKey(id));
      final String? raw = record?.data;
      if (raw != null) {
        approverId = EnrollDataStoreValue.fromJson(jsonDecode(raw))
            .approvedByEnrollmentId;
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
    // cascade, and let the verb report success on a partial revocation — and
    // the memo would then serve that answer to every other candidate whose
    // chain runs through this id. Before this walk existed the same fault
    // aborted the revoke and wrote nothing; failing closed keeps that.
    memo[id] = approverId;
    return approverId;
  }

  /// Every enrollment that reaches [enrollmentId] by following approver links
  /// upward, to any depth. Never contains [enrollmentId].
  ///
  /// Walked UPWARD from each candidate rather than downward from the target,
  /// and the difference is load-bearing. A downward walk has to ENUMERATE the
  /// intermediate links to learn their edges, and key enumeration hides
  /// records whose ttl has elapsed — so an expired enrollment part-way down an
  /// approval chain took its edge with it and every enrollment behind it
  /// survived the cascade.
  ///
  /// Depth here is not a legacy shape to be tolerated: an enrollment holding
  /// `__manage` may admit another that holds `__manage` too, so approval
  /// chains are arbitrarily deep and arbitrarily wide by design, and this
  /// server mints them in the ordinary course of admitting administrators.
  ///
  /// Upward, only the CANDIDATES need enumerating — and a candidate a cascade
  /// could revoke is by definition a live one — while each link in the chain
  /// is fetched by key, which returns expired records.
  ///
  /// ⚠️ A SEVERED link orphans everything behind it, because nothing records
  /// an enrollment's ancestry beyond its immediate approver. Two things sever
  /// one, and the second is not an edge case:
  ///
  /// * `enroll:delete` on a middle link.
  /// * the scheduled expiry sweep. Fetching by key crosses a link whose ttl
  ///   has elapsed, but the server also runs a periodic `deleteExpiredKeys()`
  ///   pass, so that window closes within tens of seconds and the record is
  ///   then gone for good. This needs a MIDDLE link, so it reaches a chain of
  ///   two or more — which, approval being unbounded, is an ordinary shape
  ///   rather than a remnant. A middle link expires before the enrollments
  ///   behind it whenever its ttl is the shorter, and a revoke arriving after
  ///   the sweep reaches the first live candidate and stops.
  ///
  ///   ⚠️ Retirement does not mint this, though it is the one thing that
  ///   would: a retrofit's cap puts a deadline on an approver without asking
  ///   whether anything sits behind it. Arming that cap moves the approver's
  ///   children onto the successor — see [_adoptApprovalChildren] — so the
  ///   link that expires has nothing behind it to orphan.
  ///
  /// Closing that needs ancestry that outlives the record, which this does not
  /// have.
  ///
  /// Every status is followed. A revoked or expired enrollment part-way down
  /// an approval chain must not hide the enrollment behind it, which is
  /// exactly the orphan a cascade exists to remove.
  ///
  /// ⚠️ This follows the APPROVAL edge only. The replacement edge —
  /// [EnrollDataStoreValue.parentEnrollmentId], what a retrofit replaced — is
  /// not walked: a retrofit produces a peer, the same principal re-keyed, so
  /// revoking a superseded credential must not take the one that superseded
  /// it. A successor is reached instead through the approver it INHERITS from
  /// its predecessor, which is what stops a retrofit being an escape hatch.
  Future<Set<String>> descendantsOf(String enrollmentId) async {
    final Set<String> found = {};
    final Map<String, String?> memo = {};
    for (final ek in await getAllEnrollmentKeys()) {
      final String candidate = getIdFromKey(ek);
      if (candidate == enrollmentId) continue;
      // `seen` terminates the climb. The enroll verb cannot build a cycle — an
      // approver is an already-approved enrollment and the one it admits is
      // minted with a fresh id — but a walk over stored data should not have
      // to rely on that to terminate.
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
  /// Nothing records ancestry beyond an enrollment's immediate approver, so a
  /// severed link orphans everything behind it: a later revoke of the chain
  /// above reaches the first live candidate and stops, and the reactivation
  /// refusal then permits un-revoking exactly what a cascade had swept.
  /// [descendantsOf] documents that, for `enroll:delete` and for the expiry
  /// sweep. A retrofit's cap would ADD a third way in and make it routine —
  /// it puts a thirty-day deadline on an approver without asking whether
  /// anything sits behind it, so an ordinary retrofit of an administrator
  /// would sever the chain a month later.
  ///
  /// The successor is where those enrollments belong. It is the same principal
  /// re-keyed and stands where its predecessor stood: it already INHERITS the
  /// predecessor's approver, and this is that same substitution seen from the
  /// other side. It also stops retiring a superseded credential taking down
  /// everything that credential ever admitted, which is the hazard that put
  /// the cascade on the approval edge to begin with.
  ///
  /// Never moves the successor onto itself. The successor inherits its
  /// predecessor's approver rather than naming the predecessor, so it is not
  /// among these children — but a self-approving record would be a cycle in
  /// stored data, and that is not worth leaving to an invariant elsewhere.
  Future<void> _adoptApprovalChildren(
      String predecessorId, String successorId) async {
    for (final ek in await getAllEnrollmentKeys()) {
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
      if (child.approvedByEnrollmentId != predecessorId) continue;

      final EnrollmentStatus? status =
          EnrollmentStatus.values.asNameMap()[child.approval?.state ?? ''];
      if (status == null) {
        logger.warning('Not re-parenting $childId onto $successorId: its '
            'approval state ${child.approval?.state} is unreadable');
        continue;
      }

      child.approvedByEnrollmentId = successorId;
      record.data = jsonEncode(child.toJson());
      // The child's own expiry must not move: a plain write re-derives it from
      // the retained ttl and would restart its clock at this moment.
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
  /// * **A predecessor whose retirement would leave the atSign with no
  ///   unexpiring root.** The predecessor holds full privilege and no OTHER
  ///   approved root without an expiry would survive it, so capping it leaves
  ///   nobody able to give the atSign a root back. The successor is not
  ///   special-cased: it stands in that walk like any other enrollment, and an
  ///   unexpiring root successor — what a plain retrofit produces — satisfies
  ///   it, so the cap arms. The successor's own lifetime is never consulted,
  ///   which is what keeps the grace setting from working backwards.
  ///
  /// Runs under [_capArmingLock], which is what makes "no other unexpiring
  /// root survives" a safe thing to act on: the walk and the cap that follows
  /// it are one critical section, so a concurrent arming cannot cap the very
  /// root this one counted.
  ///
  /// Never throws. This runs after an authentication has already succeeded, and
  /// a predecessor that outlives its window is a slower migration, while an
  /// authentication refused because bookkeeping failed is an outage.
  Future<void> armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
    await _capArmingLock
        .protect(() => _armRetrofitCapOnFirstAuth(successorEnrollmentId));
  }

  Future<void> _armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
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

          // Spared only when capping would leave the atSign unable to restore
          // itself: the predecessor holds FULL privilege and no OTHER approved
          // root without an expiry would be left behind. Full privilege rather
          // than the ability to approve, because approving is checked per
          // namespace against what the approver holds — a `__manage`-only
          // enrollment can admit new enrollments and can never admit one
          // carrying `*`, so it keeps an atSign running without being able to
          // give it a root back.
          //
          // ⛔ The successor gets NO shortcut here, though satisfying this is
          // the ordinary reason a retrofit's cap arms. It is in the keystore,
          // approved, and is not the excluded predecessor, so the walk finds
          // it on the walk's own terms. A separate deadline-relative test used
          // to short-circuit that walk, and it went on asking whether the
          // successor outlived the deadline after the walk had been given a
          // stricter question — so a successor whose posture merely EXCEEDED
          // the grace skipped the check entirely and the predecessor was
          // capped with nothing verified. Asking for a LONGER-lived credential
          // switched the protection off. One question, asked in one place, is
          // what stops that recurring.
          //
          // The cost is a keystore walk per retrofit successor rather than per
          // decline, bounded by the `predecessorCapArmedAt` stamp: it runs
          // once for a successor that arms.
          final successorExpiry =
              (await keyStore.get(key))?.metaData?.expiresAt;
          if (predecessor.isRootEnrollment &&
              !await hasUnexpiringRootEnrollment({predecessorId})) {
            // The REMEDY is named, because a decline is otherwise a dead end
            // the operator cannot see out of. An atSign whose only root asks
            // for a bounded key life declines here on every authentication,
            // and the same stranding rule refuses both routes that could
            // revoke that root — so the predecessor is un-retirable and
            // nothing anywhere says what would change that. What changes it
            // is another root that does not expire; once one exists this
            // decline stops firing on the next authentication, and the
            // predecessor can then be retired by ordinary means.
            logger.warning(
                'Not capping $predecessorId at $deadline on the word of '
                '$successorEnrollmentId, which expires at $successorExpiry: '
                '$predecessorId holds full privilege and no other approved '
                'root without an expiry would be left. The atSign would be '
                'left unable to restore a root. To retire $predecessorId, '
                'first approve an enrollment holding rw on both '
                '${EnrollmentConstants.allNamespaces} and '
                '${EnrollmentConstants.enrollManageNamespace} with NO key '
                'expiry, and then revoke or delete $predecessorId');
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
        } else {
          // Only once the predecessor really is on its way out. The two
          // outcomes above leave it live and the stamp is taken back, so its
          // children stay where they are. `predecessorGone` adopts too: those
          // children are orphans already, and the successor is what they
          // should have been hanging off.
          await _adoptApprovalChildren(predecessorId, successorEnrollmentId);
        }
      }
    } catch (e) {
      logger.warning('Could not arm the retrofit cap for '
          '$successorEnrollmentId: $e');
    }
  }
}
