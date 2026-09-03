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

  /// The atSign's ONE enrollment-mutation critical section.
  ///
  /// Store-wide rather than per record, and that is the whole of why a single
  /// lock is the right shape. Every enrollment mutation is read-decide-write
  /// over a keystore with no compare-and-set, and the decision each write
  /// rests on is a question about the WHOLE store — "would any unexpiring
  /// root survive this act?" above all. Two mutations of two DIFFERENT
  /// records therefore each pass an individually correct check and strand the
  /// atSign between them: two concurrent `enroll:revoke` commands each counted
  /// the root the other was about to remove and left zero unexpiring roots,
  /// and a retrofit cap arming alongside a revoke did the same. A per-record
  /// lock cannot see any of that, because neither writer touches the other's
  /// record.
  ///
  /// It closes the plain lost update as well, which a per-record lock WOULD
  /// have closed: a revoke and a cap arming each write a whole-record
  /// snapshot, so whichever wrote second reinstated what the other had just
  /// left — the verb answering `revoked` over a record the store held
  /// `approved`, with that credential's published `_apsk` back at the live
  /// address.
  ///
  /// READS are deliberately outside it. Enrollments are read on every verb
  /// command and on every authorisation check, so serialising reads would put
  /// the whole atSign behind one queue; a reader can still observe a cascade
  /// part-applied, exactly as it could before.
  ///
  /// That is only safe because a read is read-only, which it once was not:
  /// [getEnrollmentByFullKey] used to REMOVE a record whose ttl had elapsed,
  /// so an authorisation check could mutate the store while a mutation of
  /// another record was in flight. It reports the expiry now and leaves the
  /// record to the scheduled expired-keys pass.
  ///
  /// One instance per atSign, built once by `AtSecondaryServerImpl`, so an
  /// instance field is the whole of the contention.
  final Mutex _mutationLock = Mutex();

  /// Marks the zone a [serialiseMutation] action runs in, so a mutation
  /// reached from INSIDE another one can be told from a genuinely concurrent
  /// one. Zone values propagate across every await in the action, which is
  /// what makes the distinction hold for asynchronous code.
  static const Object _inMutationZoneKey = #atEnrollmentMutation;

  /// Runs [action] as this atSign's only in-flight enrollment mutation.
  ///
  /// Wrap the whole read-decide-write, never just the write. The write is not
  /// what races; the decision the write rests on is.
  ///
  /// RE-ENTRANT, and [Mutex.protect] is not: a nested `protect` never
  /// completes, so getting the nesting wrong costs a permanent hang on the
  /// authentication path rather than a wrong answer. An action reached from
  /// inside another one is already in the critical section and runs straight
  /// through. A genuinely concurrent caller arrives in a different zone and
  /// waits.
  Future<T> serialiseMutation<T>(Future<T> Function() action) {
    if (Zone.current[_inMutationZoneKey] == true) return action();
    return _mutationLock.protect(
        () => runZoned(action, zoneValues: {_inMutationZoneKey: true}));
  }

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
  /// Cache is used by [getEnrollmentByFullKey]. It is invalidated by [put],
  /// and by [postRemoveHook] for every removal of an enrollment key however
  /// that removal was reached — [remove], the `delete` verb, or the scheduled
  /// expired-keys sweep. [getEnrollmentByFullKey] additionally declines to
  /// populate it at all when an enrollment changed while its store read was
  /// in flight, because the value it holds is then the one from before that
  /// change.
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
  /// will be set to `expired`. The record is NOT removed — see
  /// [getEnrollmentByFullKey], which this delegates to.
  ///
  /// Returns:
  ///   An [EnrollDataStoreValue] containing the enrollment details.
  ///
  /// Throws:
  ///   [KeyNotFoundException] if the enrollment key does not exist or has expired.
  Future<EnrollDataStoreValue> getEnrollmentById(String enId) async {
    return getEnrollmentByFullKey(buildEnrollmentKey(enId));
  }

  /// An enrollment id in the form the keystore holds it in.
  ///
  /// An enrollment id is a key COMPONENT, so the keystore's fold applies to it
  /// whether or not anything above the keystore folds: `' Abc'`, `'A bc'` and
  /// `'abc'` all address one enrollment record. Comparisons above the store
  /// are exact `String ==`, so a handler holding an unfolded spelling asks
  /// about a string that is not on disk while READING AND WRITING the record
  /// that is — which makes every identity guard on that path answer "not the
  /// same enrollment" about the enrollment it is acting on.
  ///
  /// [canonicalAtKey] rather than a fold spelled out here: the answer has to
  /// be the keystore's answer, and two spellings of it can drift with nothing
  /// going red.
  ///
  /// Folding rather than REFUSING a non-canonical spelling. The keystore
  /// already resolves one to the same record, so folding cannot widen which
  /// record a caller reaches — it only makes the guards ask about the record
  /// actually being served. Refusing would be stricter but would break
  /// deployed clients that send a mixed-case id today, which works.
  static String canonicalEnrollmentId(String enId) => canonicalAtKey(enId);

  /// [canonicalEnrollmentId] for a value that may be absent, so that an entry
  /// point reading an optional id from the wire can fold it in one step.
  static String? canonicalEnrollmentIdOrNull(String? enId) =>
      enId == null ? null : canonicalEnrollmentId(enId);

  /// Constructs the enrollment key based on the provided [enId].
  ///
  /// The key format combines the [enId], a new enrollment key pattern,
  /// and the current AtSign.
  ///
  /// CANONICAL: the result is byte-identical to what an enumeration such as
  /// [getAllEnrollmentKeys] returns for that record. That is what lets a key
  /// built here be COMPARED against an enumerated one — [excluding] in
  /// [hasUnexpiringRootEnrollment] does exactly that, and a raw key built from
  /// a non-canonical id silently matched nothing there, so the last-root
  /// refusal counted the enrollment the act was removing and let an atSign
  /// lose its last root.
  ///
  /// The id is folded BEFORE it is composed as well as after, and the gap
  /// between the two is narrow enough to be worth naming. Composition moves
  /// whatever TRAILS the id into the middle of the key, where the fold's trim
  /// can no longer reach it; the space-strip catches a plain space and nothing
  /// else. So a trailing tab, no-break space or ideographic space survives
  /// composition and builds a key naming no record at all, while
  /// [canonicalEnrollmentId] would have folded it away. Leading whitespace is
  /// still leading after composition, so it was never the half that got
  /// through.
  ///
  /// Folding here rather than demanding a folded id means a caller gets the
  /// record its id addresses whether or not it folded first — which is the
  /// same posture [canonicalEnrollmentId] takes, and for the same reason.
  ///
  /// Returns:
  ///   A [String] representing the enrollment key.
  String buildEnrollmentKey(String enId) {
    return canonicalAtKey('${canonicalEnrollmentId(enId)}'
        '.${EnrollmentConstants.enrollmentKeyPattern}'
        '.${EnrollmentConstants.enrollManageNamespace}'
        '$atSign');
  }

  /// The atSign's legacy PKAM credential, or NULL when it holds none that
  /// could authenticate anybody.
  ///
  /// PRESENT is not the bar, NON-EMPTY is. The server refuses an empty public
  /// key before it looks at any signature — `PkamVerbHandler`'s
  /// `publicKey.isEmpty` guard, which covers the legacy and APKAM branches
  /// alike — so a zero-length value is a credential nobody can authenticate
  /// with, and every caller here must read it exactly as it reads the key
  /// being gone: an empty value is not a credential, so it must not be
  /// counted as one by [hasUnexpiringRootEnrollment], which is the caller
  /// that decides whether an act would strand the atSign.
  ///
  /// Zero-length is a state the atSign can be found in even though no route
  /// on this server writes one any more: both spellings of `update` now
  /// demand a non-empty value, but a store written by an older server, when
  /// `update:json` carried the value inside a JSON document nothing checked,
  /// can still hold one. The guard is kept because a credential read as
  /// present-but-empty is the one mistake that strands an atSign.
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
  /// per record. Every write still bumps [cacheInvalidations], which is
  /// what stops a read that a write overtook from repopulating the cache.
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
    // The comparison below is against the `EnId` segment of a key the
    // KEYSTORE returned, so it is canonical; an id that is not compares
    // unequal to its own data and the move silently does nothing. A revoke
    // that moves nothing leaves the enrollment's per-enrollment keys — its
    // published `_apsk` among them — sitting in the APPROVED location, which
    // is what every reader of that data goes by.
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

  /// Canonical for the same reason [buildEnrollmentKey] is, and the id is
  /// folded first for the same reason: this key is compared against keys an
  /// enumeration returned — `keys:` authorises a caller for its own encryption
  /// keys by name, and the orphan sweep matches enumerated candidates against
  /// built ones.
  String keyForPEK(String enId) =>
      canonicalAtKey('${canonicalEnrollmentId(enId)}'
          '.${AtConstants.defaultEncryptionPrivateKey}'
          '.${EnrollmentConstants.enrollManageNamespace}'
          '$atSign');

  /// Canonical for the same reason as [keyForPEK].
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
  /// AFTER rather than in [preRemoveHook], and that is the whole of why it is
  /// a second hook: the pre-hook runs while the record is still on disk and
  /// does several awaits of its own, so anything invalidated there is
  /// reinstated by any read arriving before the delete lands. There is
  /// nothing left to read back by the time this runs.
  ///
  /// A hook rather than a line in [remove], because [remove] is not the only
  /// way an enrollment key leaves the keystore — `delete` from an owner
  /// connection and the scheduled expired-keys sweep both go straight to
  /// [AtKeyValueStore.remove]. Those paths left the record cached, so it went
  /// on being served as approved for the life of the process, and went on
  /// authorising every verb its grants covered, with nothing on disk to say
  /// so.
  ///
  /// The key is canonicalised because the cache is keyed by
  /// [buildEnrollmentKey], which is, while a keystore hands its hooks the key
  /// as the caller spelled it apart from case.
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
    if (!keyStore.preRemoveHooks.contains(preRemoveHook) ||
        !keyStore.postRemoveHooks.contains(postRemoveHook)) {
      throw StateError('Managing datastore consistency for enrollments requires'
          ' that the preRemoveHook and the postRemoveHook be active');
    }
    String ek = buildEnrollmentKey(enId);

    // The cache is invalidated by [postRemoveHook], which the guard above
    // insists on, rather than by a line here: this method is one removal path
    // among several and the invariant belongs where every path passes.
    await keyStore.remove(ek, skipCommit: true);
  }

  /// Every enrollment record key this atSign holds.
  ///
  /// [includeExpired] picks between two genuinely different rosters, and it is
  /// REQUIRED so that each call site states which one it means.
  ///
  ///   * `false` — the VISIBLE roster: what [AtKeyValueStore.getKeys] returns,
  ///     which omits a record whose ttl has elapsed even though the record is
  ///     still on disk.
  ///   * `true` — the STORED roster: everything the keystore holds, expiry
  ///     included. This is what [AtKeyValueStore.get] and
  ///     [AtKeyValueStore.exists] see, and it is what the atSign actually
  ///     holds.
  ///
  /// The two disagree for tens of seconds at a stretch. Expiry is lazy here:
  /// a record stops being enumerated the instant its ttl elapses, and is
  /// removed later by the scheduled expired-keys pass, which re-arms off the
  /// store's own next expiry and is floored and jittered. Anything deciding
  /// what the atSign IS — whether it has ever been enrolled, whether a key is
  /// orphaned, which children a re-parent must reach — must take the stored
  /// view, because the visible roster is one an enrollment's own key-expiry
  /// posture empties on a schedule its holder chose. Anything merely
  /// REPORTING the roster can take the visible one.
  Future<List<String>> getAllEnrollmentKeys(
      {required bool includeExpired}) async {
    if (!includeExpired) {
      return (await keyStore
              .getKeys(regex: EnrollmentConstants.enrollmentsRegex))
          .toList();
    }
    // `getKeys` has no include-expired form, so the stored roster comes off
    // `scanKeys`, which does. An unrestricted [KeyPattern] matches every key
    // without parsing it, so this is the same whole-store walk `getKeys`
    // makes, filtered by the same expression rather than by the backend — and
    // both walks decode their keys identically, so a key enumerated here is
    // byte-identical to the one the visible roster would have returned.
    final RegExp re = RegExp(EnrollmentConstants.enrollmentsRegex);
    final List<String> keys = [];
    await for (final String key in await keyStore.scanKeys(const KeyPattern(),
        includeExpired: true)) {
      if (re.hasMatch(key)) keys.add(key);
    }
    return keys;
  }

  /// Every stored enrollment, as its id and decoded value: expired records
  /// included, each reporting its state as `expired` the way
  /// [getEnrollmentByFullKey] does. For the questions that have to be asked
  /// of the WHOLE roster before a write — whether a key is already held,
  /// whether an (appName, deviceName) is already taken.
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
  /// Every status counts, expired-but-unswept records included: a key
  /// material installed under two names is two identities with separate
  /// lifecycles, whatever state the first one is in, and a revoked or denied
  /// holder blocks re-enrolment with the same keypair until it is deleted.
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
  /// Decoded rather than compared as strings because one key has several
  /// spellings: hex decodes case-insensitively, and base64 tolerates
  /// surrounding whitespace. A uniqueness rule that compared the spelling
  /// would be defeated by re-casing.
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

  /// Fetch an enrollment key from the keystore.
  /// If key is available returns [EnrollDataStoreValue],
  /// else throws [KeyNotFoundException]
  ///
  /// READ-ONLY. A record whose ttl has elapsed comes back with its approval
  /// state reported as `expired`, and is left exactly where it is.
  ///
  /// It used to REMOVE such a record, and that write had no business on this
  /// path. Enrollments are read on every verb command and on every
  /// authorisation check, all of it deliberately outside the atSign's one
  /// enrollment-mutation critical section — so the reap was a store mutation
  /// taken by a reader that had decided nothing, while a mutation of another
  /// record was in flight. `remove` also fires the pre-remove hook, which
  /// does several awaits of per-enrollment data movement — work an
  /// authorisation check taken on every verb command has no business running.
  ///
  /// The manager's own readers had already worked around it one at a time —
  /// [approvedRootEnrollmentsAmong], [_approverIdOf] and the descendant walk
  /// each read straight through the keystore to avoid reaping while deciding
  /// whether to REFUSE something. [hasUnexpiringRootEnrollment] did not, so
  /// the last-root decision — the one place a stranding is being judged —
  /// reaped as it walked. Fixing the read is what makes that consistent
  /// without every caller having to know.
  ///
  /// Nothing is leaked by not reaping here. The server sweeps expired keys on
  /// a timer it re-arms from the store's own next expiry — floored at ten
  /// seconds and jittered by up to thirty, so a record is removed within tens
  /// of seconds of expiring — and that pass removes them through the same
  /// [AtKeyValueStore.remove], so the same hooks fire. The value handed back
  /// is identical either way, because callers decide on the `expired` state
  /// rather than on the record's absence.
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
      // The generation the value is read AT. The store read below is an
      // await, so an enrollment write can land while it is in flight — and
      // the value it hands back is then the one from BEFORE that write.
      // Caching it unconditionally reinstates the superseded record after the
      // writer has already invalidated it, and nothing invalidates it again:
      // the entry outlives the process's memory of the write. Measured as a
      // PKAM that succeeded for an enrollment the store said was revoked.
      //
      // The counter is bumped by every enrollment write and every enrollment
      // removal, so this is deliberately coarse — a write to some OTHER
      // enrollment costs this read its cache fill, which the next read pays
      // again. That is the whole cost, and it buys the invariant with no new
      // state: enrollments are written extremely rarely compared to how often
      // they are read, which is why there is a cache here at all.
      final int generationAtRead = cacheInvalidations;
      enrollData = (await keyStore.get(ek))!;
      enrollJson = jsonDecode(enrollData.data!);
      if (cacheInvalidations == generationAtRead) {
        atDataCache[ek] = (enrollData, enrollJson);
      }
    }

    EnrollDataStoreValue value = EnrollDataStoreValue.fromJson(enrollJson);
    if (!SecondaryUtil.isActiveKey(enrollData)) {
      // Reported, never repaired. See the doc comment: removing it here is a
      // write on a path every authorisation check takes.
      logger.finer('getEnrollmentByFullKey:'
          ' Enrollment $ek has expired - reporting it expired. The scheduled'
          ' expired-keys pass is what removes it');
      value.approval = EnrollApproval(EnrollmentStatus.expired.name);
    }
    return value;
  }

  /// Fetch enrollments whose keys are in the [ekList], and filter them to
  /// enrollments whose status is in the [statuses] list.
  ///
  /// When [ekList] is null, fetch and filter all enrollments.
  /// When [statuses] is null, do not filter by status.
  ///
  /// [redactSecrets] selects the roster projection
  /// ([EnrollDataStoreValue.toJsonRoster]) instead of the full record. It is
  /// REQUIRED rather than defaulted: every caller has to state which audience
  /// it is answering, because the full record carries the wrapped APKAM
  /// symmetric key and a caller that gets it by omission is the defect this
  /// parameter exists to prevent.
  Future<Map<String, Map<String, dynamic>>> getEnrollmentsAsJson(
      {required bool redactSecrets,
      List<String>? ekList,
      List<EnrollmentStatus>? statuses}) async {
    // set default values for optional arguments - all enrollments, all statuses
    //
    // The VISIBLE roster: this REPORTS a roster (`enroll:list`), it decides
    // nothing. A record the keystore has stopped serving is one this atSign has
    // finished with, and listing it would make the answer depend on how
    // recently the expiry sweep happened to run.
    ekList ??= await getAllEnrollmentKeys(includeExpired: false);

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
        ejList[ek] =
            redactSecrets ? enVal.toJsonRoster() : enVal.toJsonExtended();
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
    // The VISIBLE roster, and here the two views cannot differ in the ANSWER:
    // a record the visible roster omits is one [getEnrollmentByFullKey] would
    // report `expired`, and the approved-only filter below drops it either way.
    // Visible is the cheaper of two identical answers.
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
  ///
  /// Over the STORED roster, and that is what makes the repair complete.
  /// Nothing else ever revisits one of these keys: the pre-remove hook does not
  /// remove it, so an enrollment skipped here because its ttl had elapsed is
  /// reaped by the expiry sweep and leaves its app and device names published
  /// for the life of the atSign.
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

  /// Called upon server startup. Removes encryption keys of enrollments which
  /// no longer exist (expired or otherwise). Previously these encryption keys
  /// were stored without a ttl even if there was a valid ttl, therefore they
  /// would never be harvested.
  Future<List<String>> removeOrphanedApkamEncryptionKeys() async {
    final List<String> deletedOrphanedKeys = [];
    final List<String> enIds = [];
    // The STORED roster, because ORPHANED means "no record holds it" and a
    // record whose ttl has elapsed is still a record that holds it. Deciding
    // from the visible roster deletes an enrollment's encryption keys while its
    // record is still on disk, ahead of the expiry sweep — which removes them
    // itself, through the pre-remove hook, as part of removing the record.
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
  /// ⚠️ APPROVED is load-bearing, not incidental. Any approved, permanent,
  /// fully privileged record can be REVOKED, and this walk runs while the
  /// records a cascade is about to take are still `approved` on disk — so
  /// counting one that is leaving reports the atSign safe at exactly the
  /// moment its last usable root is taken away.
  ///
  /// Full privilege rather than the ability to approve, because approving is
  /// checked per namespace against what the approver itself holds — `__manage`
  /// included, so an approver holding `__manage:r` confers no more than
  /// `__manage:r`. An enrollment with `__manage` but not `*` can admit new
  /// enrollments and can never admit one carrying `*`, so it keeps an atSign
  /// running without being able to give it a root back.
  ///
  /// ⚠️ A record with NO CREDENTIAL RECORDED for it is not a root, whoever it
  /// is. Every "is this a root?" question below applies
  /// [isUsableRootEnrollment] rather than [EnrollDataStoreValue.isRootEnrollment]
  /// alone, because a fully privileged, approved, permanent record with an
  /// empty public key is a PHANTOM root: counting it answers "the atSign can
  /// restore a root" with an identity no signature can ever be checked
  /// against, which is the same stranding this method exists to refuse,
  /// arrived at from the other direction. What that bar does and does not
  /// establish is set out on [isUsableRootEnrollment].
  ///
  /// [excluding] is a SET rather than a single id because a revoke CASCADES.
  /// The enrollments a cascade is about to revoke are still `approved` in the
  /// keystore while this runs, so asking the question without them would count
  /// the very enrollments the act is about to remove — and report the atSign
  /// safe at the moment it is being stranded.
  Future<bool> hasUnexpiringRootEnrollment(Set<String> excluding) async {
    // The FLAT credential counts, and it is asked about first because it is
    // one key read against a whole-keystore walk.
    //
    // It is a usable root by every measure this method applies: a `pkam:`
    // carrying no enrollment id is verified against it and the connection it
    // admits is authorised for everything, it is answerable to no approval
    // state, and it carries no expiry. There are atSigns in the field whose
    // ONLY credential is this key, and for them it is the sole answer to
    // "could this atSign approve a replacement afterwards?".
    //
    // The retirement clock is the ONE thing that takes it away, and it cannot
    // take it away from such an atSign: before removing the key it asks this
    // same question of the roster alone, and declines when the answer is no.
    // See [retireLegacyCredentialIfDue].
    //
    // [excluding] does not reach it: that set names enrollments an act is
    // about to remove, and no enroll: verb can remove this key. It is read
    // live rather than counted from a record, because its existence IS its
    // state — there is no record, and a non-empty value at that key is
    // exactly what authentication itself requires.
    if (await legacyPkamPublicKey() != null) return true;

    return hasUnexpiringRootEnrollmentRecord(excluding);
  }

  /// The same question as [hasUnexpiringRootEnrollment], asked of the
  /// enrollment ROSTER alone: the flat credential does not count.
  ///
  /// One caller asks it this way, and it is the one act whose subject IS the
  /// flat credential: the retirement clock. Counting the key there would let
  /// it license its own removal — "something survives" answered by the very
  /// thing about to be taken away, which is the same asymmetry [excluding]
  /// exists to close for a revoke cascade.
  ///
  /// Every other caller must ask [hasUnexpiringRootEnrollment] instead. An
  /// act that leaves the flat credential in place leaves the atSign a way
  /// back, and refusing it because the ROSTER is empty would refuse revokes
  /// on precisely the atSigns this whole retrofit exists to serve.
  Future<bool> hasUnexpiringRootEnrollmentRecord(Set<String> excluding) async {
    final excludedKeys = excluding.map(buildEnrollmentKey).toSet();
    // The STORED roster. The two views cannot differ in the answer — a record
    // the visible roster omits is either not `approved` here or carries the
    // non-null `expiresAt` this rejects on — but a stranding decision is a
    // question about what the atSign HOLDS, and answering it from a roster that
    // thins on a timer is how the same act becomes safe or unsafe according to
    // when the sweep last ran.
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

  /// Whether [value] is a root the atSign could fall back on: fully privileged
  /// AND with a non-empty public key recorded for it.
  ///
  /// THAT IS THE WHOLE BAR, and it is exactly the bar authentication itself
  /// applies before it looks at a signature: `PkamVerbHandler` refuses an
  /// empty public key on the legacy and APKAM branches alike, so an empty
  /// value and a missing one are the same credential — none. Zero-length is
  /// reachable rather than theoretical, and the route that reaches it is
  /// `enroll:request`: an enrollment record's `apkamPublicKey` is whatever
  /// the request was sent, and no update-path validation stands between a
  /// request and the record it writes.
  ///
  /// It is applied on both sides of every stranding decision — what an act
  /// REMOVES and what SURVIVES it — so that "root" means one thing in both. A
  /// guard that counted a record as a root when asked one and not the other is
  /// the asymmetry that lets an act be licensed by a record the same act is
  /// destroying.
  ///
  /// ⚠️ WHAT IT DOES NOT ESTABLISH is that anybody holds the private half. The
  /// server never sees a private key, so a key whose holder has lost it, or
  /// which was never held by anyone, is indistinguishable here from a live
  /// one. This method cannot close that and must not be read as though it
  /// does; "usable" means a signature could be CHECKED against this record,
  /// not that one could be produced for it.
  ///
  /// Possession is established where the key is WRITTEN instead, which is the
  /// one moment the server can demand a proof: `enroll:update` refuses a new
  /// `apkamPublicKey` without a signature by the private half of the key
  /// being installed.
  ///
  /// What that leaves uncovered, stated so nobody has to rediscover it:
  /// `enroll:request` installs an `apkamPublicKey` with no proof at all, so an
  /// enrollment approved but never yet authenticated with can pass this bar
  /// holding a key nobody holds. Its possession is proved on its first `pkam:`
  /// and not before.
  ///
  /// MEASURED, in three arms differing only in the bytes stored at a root's
  /// public key: a well-formed key whose private half was never persisted
  /// left that root counted as the atSign's surviving unexpiring root — the
  /// bar is a credential something can authenticate with, and a well-formed
  /// orphan passes it — while nothing could authenticate as it, so revoking
  /// the last root that really worked was permitted. Stored EMPTY it was not
  /// counted and the revoke was refused; left alone it was counted and
  /// authentication worked. The server cannot tell an orphan from a live key
  /// after the fact, which is why the demand is made at the write.
  ///
  /// [enrollmentId] identifies the record for the caller's own reporting; the
  /// verdict is a property of [value] alone. The FLAT credential is not an
  /// enrollment and is not asked about here — it has no record to be passed
  /// in. [hasUnexpiringRootEnrollment] reads it directly.
  ///
  /// This is NOT the question `isRootPrivilegedConnection` asks. That one
  /// decides what an already-authenticated connection may do. This one asks
  /// whether a record would still be there to authenticate as afterwards.
  bool isUsableRootEnrollment(
      String enrollmentId, EnrollDataStoreValue value) {
    if (!value.isRootEnrollment) return false;
    return value.apkamPublicKey.isNotEmpty;
  }

  /// Where the flat credential's retirement DEADLINE is stored.
  ///
  /// A key of its own rather than a ttl on the credential itself. A ttl would
  /// have the store delete the key on its own schedule, and the removal has a
  /// question to ask first — whether it would strand the atSign — which an
  /// expiry sweep has no way to ask and no way to answer "no" to.
  ///
  /// Unwritable and undeletable from the wire, and measured rather than
  /// assumed: the name carries a ':', which neither spelling of `update` will
  /// accept — the grammar's atKey charset admits one colon-bearing literal
  /// and this is not it, and `update:json` is held to that same charset — and
  /// `AtKey.getKeyType` calls it `privateKey`, which the update seam refuses
  /// outright behind that; `delete` whitelists only `privatekey:at_secret`. It never syncs either — the commit log returns
  /// without writing for every key on the `private:` prefix.
  ///
  /// The `privatekey:` prefix the credential itself uses is NOT available:
  /// the keystore refuses any key it types as `invalidKey`, and every
  /// `privatekey:` name outside at_commons' fixed reserved list is one.
  String get legacyCredentialRetirementKey =>
      'private:at_pkam_publickey_retire_after$atSign';

  /// Starts the flat credential's retirement clock, ONCE.
  ///
  /// Called when a connection carrying no enrollment id of its own — the
  /// atSign's owner, over CRAM or over the flat credential itself — mints an
  /// approved enrollment. That is the moment the atSign acquires a credential
  /// that CAN be withdrawn, and it is what the migration window is measured
  /// from. Also called at startup, through
  /// [armLegacyCredentialRetirementIfAlreadyEnrolled], for an atSign whose
  /// owner did that minting before this server ever ran.
  ///
  /// It arms once and never re-arms. A deadline is written as an absolute, so
  /// a second arming would push it out by a whole window — an owner who mints
  /// an enrollment a month would keep the flat credential for ever, which is
  /// the opposite of what the clock is for.
  ///
  /// It does not arm at all on an atSign holding no flat credential, which is
  /// every atSign onboarded by this server: there is nothing to retire, and a
  /// deadline written against an absent key would fire on a credential
  /// installed later for some entirely different reason.
  ///
  /// Best-effort, and deliberately so: a failure here must not fail the
  /// enrollment the owner asked for. The clock is a migration aid, and an
  /// atSign that keeps its flat credential a while longer is in the state it
  /// was already in.
  /// Arms the retirement clock at startup for an atSign that ALREADY holds
  /// enrollments alongside its flat credential.
  ///
  /// [armLegacyCredentialRetirement] fires when an owner mints an enrollment,
  /// and an atSign onboarded by an older server may have done all its minting
  /// before this server ever ran — leaving its flat credential, and the stale
  /// copy of an app's key an older server's CRAM auto-approve wrote there,
  /// with no clock ever started. Holding enrollments IS migration having
  /// begun, so the clock starts now.
  ///
  /// This is a startup step of the kind that was withdrawn for MINTING an
  /// identity, and it is safe where that was not: it schedules a REMOVAL that
  /// [retireLegacyCredentialIfDue] guards with the stranding question, so
  /// arranging the store beforehand can only delay it, never gain anything.
  ///
  /// The STORED roster, expired records included: an atSign whose only
  /// enrollment has lapsed but not yet been swept has still migrated. A
  /// virgin store arms nothing — there is nothing to migrate from.
  Future<void> armLegacyCredentialRetirementIfAlreadyEnrolled() async {
    try {
      if (await legacyPkamPublicKey() == null) return;
      final List<String> stored =
          await getAllEnrollmentKeys(includeExpired: true);
      if (stored.isEmpty) return;
    } catch (e) {
      logger.warning('Could not decide whether to arm the flat PKAM '
          'credential\'s retirement clock at startup: $e');
      return;
    }
    await armLegacyCredentialRetirement();
  }

  Future<void> armLegacyCredentialRetirement() async {
    try {
      if (await legacyPkamPublicKey() == null) return;
      if (await keyStore.exists(legacyCredentialRetirementKey)) return;

      final deadline = DateTime.now().toUtc().add(Duration(
          hours: AtSecondaryConfig.legacyCredentialRetirementHours));
      await keyStore.put(legacyCredentialRetirementKey,
          AtData()..data = deadline.toIso8601String(),
          skipCommit: true);
      logger.shout(
          'This atSign\'s owner has minted an enrollment, so its flat PKAM '
          'credential (${AtConstants.atPkamPublicKey}) is scheduled for '
          'removal at $deadline. It authenticates with no enrollment id and '
          'no verb can withdraw it; enrolled credentials can be revoked. The '
          'removal will be declined if by then this is the only credential '
          'the atSign could restore itself with');
    } catch (e) {
      logger.warning('Could not arm the flat PKAM credential\'s retirement '
          'clock: $e');
    }
  }

  /// Removes the flat credential if its deadline has passed AND doing so
  /// would not strand the atSign.
  ///
  /// Run from the server's housekeeping sweep, so "the deadline elapsed" is
  /// noticed within one sweep interval of the fact and survives a restart:
  /// the deadline is a stored absolute, so a server that was down through it
  /// acts on the next tick after it comes back.
  ///
  /// ⚠️ THE DECLINE IS THE POINT, not an edge case. An atSign whose
  /// enrollments have all been revoked or have expired has nothing left to
  /// authenticate with except this key, and removing it on a timer would lock
  /// its owner out permanently — there is no verb that puts it back. So the
  /// stranding question is asked at the moment of removal rather than at the
  /// moment of arming, because the roster changes in between, and the answer
  /// leaves BOTH the key and the deadline standing: the question is re-asked
  /// on every subsequent sweep, and the clock completes if and when the
  /// atSign acquires a root enrollment it can fall back on. A clock that
  /// never completes for such an atSign is the correct outcome.
  ///
  /// The question is asked of the enrollment roster ALONE
  /// ([hasUnexpiringRootEnrollmentRecord]). Asking the ordinary
  /// [hasUnexpiringRootEnrollment] would count the flat credential itself —
  /// the thing being removed — and every removal would license itself.
  ///
  /// Arranging the state that DECLINES buys an attacker nothing. It delays a
  /// removal, and what it preserves is a credential the attacker would have
  /// to already hold the private half of; it confers no privilege that
  /// holding the key does not already confer. That is the difference between
  /// this and a mint gate, where arranging state bought the right to create a
  /// credential.
  Future<void> retireLegacyCredentialIfDue() =>
      serialiseMutation(_retireLegacyCredentialIfDueUnderLock);

  /// [retireLegacyCredentialIfDue]'s body, inside the enrollment-mutation
  /// section.
  ///
  /// It has to be: this decides on the enrollment roster ("does an unexpiring
  /// root survive?") and then removes the flat credential, which is a
  /// decide-then-write over exactly the state `enroll:revoke` mutates. Run
  /// outside the section, a sweep and a concurrent revoke each decide on state
  /// the other is about to change — the sweep removes the key because the
  /// roster still shows a root, the revoke removes that root because the key
  /// is still on disk — and the atSign ends with no usable root and no verb
  /// that can put either back. Serialised, whichever runs second sees the
  /// other's write and declines.
  ///
  /// [serialiseMutation] is re-entrant, so this is safe from any caller.
  Future<void> _retireLegacyCredentialIfDueUnderLock() async {
    final DateTime deadline;
    try {
      final AtData? record;
      try {
        record = await keyStore.get(legacyCredentialRetirementKey);
      } on KeyNotFoundException {
        return; // Never armed.
      }
      final String? raw = record?.data;
      if (raw == null) return;
      final DateTime? parsed = DateTime.tryParse(raw);
      if (parsed == null) {
        logger.severe('The flat PKAM credential\'s retirement deadline reads '
            '"$raw", which is not a timestamp. Leaving the credential alone: '
            'a removal that cannot say when it was due is not one to make');
        return;
      }
      deadline = parsed.toUtc();
    } catch (e) {
      logger.warning('Could not read the flat PKAM credential\'s retirement '
          'deadline: $e');
      return;
    }

    if (DateTime.now().toUtc().isBefore(deadline)) return;

    // DECIDING is guarded separately from ACTING, and the two removals from
    // each other. A single guard around all of it would report "could not
    // retire" for a failure that happened after the credential was already
    // gone, which is the one thing an operator reading this log must be able
    // to tell apart.
    final bool credentialStillThere;
    final bool anythingSurvivesIt;
    try {
      credentialStillThere = await legacyPkamPublicKey() != null;
      anythingSurvivesIt =
          credentialStillThere && await hasUnexpiringRootEnrollmentRecord({});
    } catch (e) {
      logger.warning('Could not decide whether to retire the flat PKAM '
          'credential: $e');
      return;
    }

    if (credentialStillThere && !anythingSurvivesIt) {
      logger.warning(
          'The flat PKAM credential (${AtConstants.atPkamPublicKey}) was due '
          'for removal at $deadline, but it is the only credential this atSign '
          'could restore itself with — no approved, fully privileged, '
          'unexpiring enrollment survives it. Keeping it. Enrol a replacement '
          'holding "*:rw" and "__manage:rw" and the removal will happen on a '
          'later sweep');
      return;
    }

    if (credentialStillThere) {
      try {
        await keyStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);
      } catch (e) {
        logger.warning('Could not remove the flat PKAM credential: $e');
        return;
      }
      logger.shout(
          'Removed this atSign\'s flat PKAM credential '
          '(${AtConstants.atPkamPublicKey}), which fell due at $deadline. '
          'Legacy `pkam:` authentication no longer works for it; every '
          'credential it holds now carries an enrollment id that can be '
          'revoked');
    }

    // Whether the credential was removed here or was already gone, the
    // deadline has nothing left to act on. One left standing would fire on
    // whatever was written to that key afterwards.
    try {
      await keyStore.remove(legacyCredentialRetirementKey, skipCommit: true);
    } catch (e) {
      logger.warning('The flat PKAM credential is gone but its retirement '
          'deadline could not be cleared: $e. The next sweep will find nothing '
          'to remove and clear it then');
    }
  }

  /// Which of [enrollmentIds] are usable roots ([isUsableRootEnrollment]) and
  /// currently approved — that is, which of them a revoke of that set would
  /// actually take away.
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
  /// Read straight through the keystore rather than via
  /// [getEnrollmentByFullKey], which decodes and caches on the way. The
  /// answer here is a status-and-grants question about a handful of named
  /// records, so the extra layer buys nothing; both reads are read-only.
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
  /// Not the enrollment [id] replaced. A retrofit produces a PEER — the same
  /// principal re-keyed — so its successor inherits this value from its
  /// predecessor rather than naming it, and revocation therefore does not
  /// travel the replacement edge at all.
  ///
  /// Deliberately NOT via [getEnrollmentByFullKey], which reports an elapsed
  /// ttl as `expired` and would make this walk decide what to do about that.
  /// `keyStore.get` returns a record whose ttl has elapsed — expiry is a
  /// judgement its callers apply — which is what lets the walk cross an
  /// expired link.
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
  /// [EnrollDataStoreValue.retrofitPredecessorEnrollmentId], what a retrofit
  /// replaced — is not walked: a retrofit produces a peer, the same principal re-keyed, so
  /// revoking a superseded credential must not take the one that superseded
  /// it. A successor is reached instead through the approver it INHERITS from
  /// its predecessor, which is what stops a retrofit being an escape hatch.
  Future<Set<String>> descendantsOf(String enrollmentId) async {
    // Canonical, because every id this is compared against comes out of a
    // keystore key or out of a stored approver link written from one. A
    // non-canonical target matches nothing and the walk returns EMPTY — which
    // reads exactly like an enrollment with no descendants, so a cascade that
    // swept nothing reported success. Measured on a two-deep chain: the
    // canonical id returned both descendants and the same id with one leading
    // non-breaking space returned none.
    enrollmentId = canonicalEnrollmentId(enrollmentId);
    final Set<String> found = {};
    final Map<String, String?> memo = {};
    // The STORED roster, so that every status really is followed. The climb
    // already reads through an elapsed record — [_approverIdOf] fetches by key
    // — but the CANDIDATE enumeration did not, so an enrollment whose ttl had
    // elapsed sat outside the cascade while its record, and its published
    // `_apsk` at the approved address, were still there.
    for (final ek in await getAllEnrollmentKeys(includeExpired: true)) {
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
  ///
  /// Runs INSIDE [serialiseMutation]; its caller holds the section. Every
  /// child here is a read-modify-write of a whole record, and this is the one
  /// place where losing that update is PERMANENT and silent: nothing ever
  /// re-parents again, so a child left naming a predecessor on its way out
  /// sits outside the revocation cascade for the rest of its life.
  ///
  /// The WHOLE loop is in the section rather than a re-read per child. A
  /// re-read would narrow the window and not close it — `put` walks the
  /// keystore before writing — and the loop is not on the authentication fast
  /// path: an authentication with nothing to arm never enters the section at
  /// all, and this runs once per successor that actually caps, behind the
  /// `predecessorCapArmedAt` stamp.
  Future<void> _adoptApprovalChildren(
      String predecessorId, String successorId) async {
    // The STORED roster. This is the pass whose omissions are PERMANENT —
    // nothing ever re-parents twice — so a child missed here names a
    // predecessor for the rest of its life and sits outside every later
    // revocation cascade. A record the visible roster omits for a ttb it has
    // not reached yet is the sharp case: it is not expiring, it is not yet
    // BORN, and it outlives this pass.
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
  /// command, null for a CRAM, owner or legacy-PKAM connection, none of which
  /// carries one; [cascadedFrom] is the
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
  /// Read immediately before the write for the same reason the stamp itself
  /// is: everything in between awaits, and a snapshot from before all of it
  /// would revert a change made since. Called from inside
  /// [serialiseMutation], so no other enrollment mutation can be that change.
  /// Best-effort — if it fails the successor stays stamped, which is the
  /// pre-existing behaviour and no worse than not trying.
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

  /// Settles what the enrollment [successorEnrollmentId] replaced, once, at
  /// the successor's first authentication: the successor is stamped as
  /// having settled it, the predecessor's approval children move onto the
  /// successor, and a predecessor that is not fully privileged is put on the
  /// retrofit cap.
  ///
  /// Usually that is the successor's very first authentication. When the
  /// predecessor is not approved, nothing is recorded and the question is
  /// asked again next time, so the settling authentication may be a later
  /// one.
  ///
  /// A no-op for an enrollment that replaced nothing, which is every
  /// enrollment except a retrofit's successor.
  ///
  /// Settled here rather than where the successor is stored because storing
  /// it proves only that the SERVER wrote a record. The successor's APKAM
  /// private half is persisted client-side, so a keyfile write that fails, a
  /// read-only file, or a process that dies before the flush each leave the
  /// successor existing on the server and nowhere else — with a clock already
  /// started on the predecessor, which is by then the only credential that
  /// still works. An authentication on a connection the successor opened is
  /// what proves the private half survived and is usable.
  ///
  /// Only the FIRST authentication of any one successor settles. Without
  /// that, every reconnect would rewrite a full grace period onto a capped
  /// predecessor and it would never retire at all.
  ///
  /// WHICH PREDECESSORS ARE CAPPED. A predecessor holding `*:rw` and
  /// `__manage:rw` keeps its life: key management is its owner's
  /// responsibility, and a clock on an atSign's root is a clock on the
  /// atSign's ability to restore itself. Every other predecessor is capped to
  /// `min(grace, what its own key-expiry posture leaves it)`. A non-root
  /// predecessor was created deliberately, by an app with enrollment tooling,
  /// for one device, so a clock there is safe and useful — and it can never
  /// be the atSign's last root, so no stranding question is asked of it.
  ///
  /// ONE CONDITION STOPS EVERYTHING, and it does not stamp the successor: a
  /// predecessor that is not approved. It is already retired, and writing it
  /// back would hand it a fresh ttl it has no business carrying. An unrevoke
  /// restores an ordinary predecessor, so this must not become permanent; it
  /// is a judgement about state that can change, re-made on the next
  /// authentication rather than frozen into the record.
  ///
  /// The decide-and-write half runs under [serialiseMutation]. The adoption
  /// is a read-modify-write of every child record and its lost update is
  /// permanent — nothing ever re-parents twice — and the stamp is a
  /// whole-record write of the successor that a concurrent revoke of the
  /// successor would otherwise overwrite or be overwritten by. It is the
  /// atSign's single enrollment-mutation lock rather than an arming-only one,
  /// because those concurrent writers are the other enrollment verbs.
  ///
  /// The EARLY EXITS are outside it, deliberately. This runs on every APKAM
  /// authentication, after the section that admitted the connection has been
  /// released, and everything except a retrofit's successor leaves at the
  /// two tests below; taking the section again for them would queue the
  /// authentication a second time, behind whatever mutation started in
  /// between, to decide nothing. Nothing in them writes, and both are re-made
  /// inside the section, so an answer that goes stale between the two costs
  /// at most a settling deferred to the next authentication.
  ///
  /// Never throws. This runs after an authentication has already succeeded, and
  /// a predecessor that outlives its window is a slower migration, while an
  /// authentication refused because bookkeeping failed is an outage.
  Future<void> armRetrofitCapOnFirstAuth(String successorEnrollmentId) async {
    try {
      // Through the cached read: the PKAM path has just read this same
      // enrollment, so it is warm.
      final EnrollDataStoreValue cached =
          await getEnrollmentById(successorEnrollmentId);
      // Replaced nothing, so there is nothing to cap. This is the exit almost
      // every authentication takes.
      if (cached.retrofitPredecessorEnrollmentId == null) return;
      // Already settled.
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
      // Re-asked inside the critical section. The same two tests ran
      // outside it so that a plain authentication never takes the lock, and
      // either can have changed while this call waited — another
      // successor's arming, or a revoke, is exactly what it waited behind.
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

      // Whether this authentication settles the predecessor — stamps the
      // successor and moves the predecessor's children — and whether the
      // predecessor is capped on the way.
      bool settled = false;
      bool capPredecessor = false;
      final bool predecessorGone = predecessor == null;

      if (predecessorGone) {
        // Settled: nothing can bring the predecessor back, and re-walking the
        // lookup on every future connection buys nothing. Its children are
        // orphans already, and the successor is what they should have been
        // hanging off.
        settled = true;
      } else if (predecessor.approval?.state != EnrollmentStatus.approved.name) {
        // Not settled, and not capped: a predecessor that is denied, revoked
        // or expired is already retired, and writing it back would give it a
        // fresh ttl it has no business carrying. Left unstamped deliberately —
        // an unrevoke restores an ordinary approved predecessor, and a
        // transient state must not become a permanent exemption.
        logger.info('Enrollment $successorEnrollmentId replaced $predecessorId, '
            'which is ${predecessor.approval?.state} — not capping it');
      } else if (predecessor.isRootEnrollment) {
        // A fully privileged predecessor keeps its life. Its children still
        // move: the successor is the same principal re-keyed and stands where
        // the predecessor stood, whatever clock the predecessor is or is not
        // on.
        logger.info('Enrollment $successorEnrollmentId replaced $predecessorId, '
            'which holds full privilege and keeps its life; what it admitted '
            'now hangs off its successor');
        settled = true;
      } else {
        settled = true;
        capPredecessor = true;
      }

      if (!settled) return;

      // Read immediately before the write. The critical section is what
      // closes the lost update — no other enrollment mutation can be in
      // flight, and the keystore has no compare-and-set to close it with —
      // and this read is what makes the record written here the one the
      // section is working from rather than a snapshot taken before the
      // predecessor lookup and the keystore walk above.
      final AtData? atData = await keyStore.get(key);
      final String? raw = atData?.data;
      if (atData == null || raw == null) return;
      final successor = EnrollDataStoreValue.fromJson(jsonDecode(raw));
      // Load-bearing, not belt-and-braces: `put` invalidates the cache only
      // after its own await, so a concurrent READER — which the critical
      // section does not serialise — can repopulate it with a pre-write
      // value. This uncached re-test is what actually makes "first" hold;
      // the cached checks at the entry point are only a fast path.
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

      // The cap goes AFTER the stamp. If a write fails between the two, the
      // successor is recorded as processed and the predecessor simply keeps
      // the expiry it already had — the migration is slower and nothing else
      // moves. The other order fails far worse: a capped predecessor with no
      // stamp is re-capped on every later authentication, each time with a
      // fresh full grace, so it never retires at all.
      if (capPredecessor) {
        final RetrofitCapOutcome outcome =
            await capEnrollmentExpiry(predecessorId);
        // That ordering means a cap which declines at the write leaves a
        // stamp claiming the question is settled when it is not, and the
        // stamp is durable while the reason was transient: the predecessor
        // was approved when the decision was taken and had been revoked by
        // the time of the write. An un-revoke would then restore it with no
        // expiry and no successor able to re-arm, forever. So the stamp is
        // taken back, and ONLY for that outcome; the predecessor is live, so
        // its children stay where they are.
        if (outcome == RetrofitCapOutcome.notApproved ||
            outcome == RetrofitCapOutcome.unreadable) {
          await _clearCapStamp(successorEnrollmentId, key);
          return;
        }
      }
      // The children move whenever the stamp stands: off a capped
      // predecessor, off a root that keeps its life, and off one that is
      // already gone.
      await _adoptApprovalChildren(predecessorId, successorEnrollmentId);
    } catch (e) {
      logger.warning('Could not arm the retrofit cap for '
          '$successorEnrollmentId: $e');
    }
  }
}
