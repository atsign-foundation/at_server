import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/wire_param_names.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/apkam_signature_verifier.dart';
import 'package:at_secondary/src/utils/handler_util.dart' as hu;
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/change_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:mutex/mutex.dart';

abstract class AbstractUpdateVerbHandler extends ChangeVerbHandler {
  static bool _autoNotify = AtSecondaryConfig.autoNotify;
  final NotificationManager notificationManager;
  static const int maxKeyLength = 255;
  static const int maxKeyLengthWithoutCached = 248;

  /// Has to be static because both UpdateVerbHandler and UpdateMetaVerbHandler
  /// need to use the same mutexes.
  ///
  /// Mutable holder rather than `(Mutex, int)` records so increments and
  /// decrements happen in place — Dart records are immutable, so the previous
  /// `map[k] = (rec.$1, rec.$2 + 1)` form allocated a fresh record on every
  /// acquire and release.
  static final Map<String, MutexRef> _updateMutexes = {};

  Map<String, MutexRef> get updateMutexes => _updateMutexes;

  final String atSign;

  AbstractUpdateVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    this.notificationManager,
    this.atSign,
  );

  //setter to set autoNotify value from dynamic server config "config:set".
  //only works when testingMode is set to true
  static setAutoNotify(bool newState) {
    _autoNotify = newState;
  }

  String getDataStoreKey(UpdateParams updateParams) {
    final sharedWith = updateParams.sharedWith;
    final sharedBy = updateParams.sharedBy;
    var atKey = updateParams.atKey!;

    // Get the key using verbParams (forAtSign, key, atSign)
    if (sharedWith != null && sharedWith.isNotEmpty) {
      atKey = '$sharedWith:$atKey';
    }
    if (sharedBy != null && sharedBy.isNotEmpty) {
      atKey = '$atKey$sharedBy';
    }
    // Append public: as prefix if key is public
    if (updateParams.metadata!.isPublic) {
      atKey = 'public:$atKey';
    }

    return atKey;
  }

  String apkamUnauthorizedMsg(String enId, String key) =>
      'Connection with enrollment ID $enId'
      ' is not authorized to update key: $key';

  /// - Construct an AtKey and AtData and AtMetaData from the verb params
  /// - Fetch existing record from data store
  /// - If existing record,
  ///   - Merge existing metadata into the new metadata where new metadata field
  ///   has a null value
  ///   - Iterate through the verb params again; if there is a metadata param
  ///   supplied with a value of 'null' then set the AtMetaData field to null
  ///
  /// The auto-notification is NOT queued here — the handler queues it via
  /// [notifyAfterStore] once the keystore write has succeeded, so the
  /// notification carries the metadata that was actually stored and a failed
  /// write queues nothing.
  Future<UpdatePreProcessResult> preProcess(
      Response response,
      HashMap<String, String?> verbParams,
      UpdateParams updateParams,
      InboundConnection atConnection) async {
    // Sets Response bean to the response bean in ChangeVerbHandler
    await super.processVerb(response, verbParams, atConnection);

    // Get the key and update the value
    final sharedBy = updateParams.sharedBy;
    final value = updateParams.value;
    final atData = AtData();
    atData.data = value;

    // Get the key we're going to update in the data store
    String atKey = getDataStoreKey(updateParams);

    // check authorization
    InboundConnectionMetadata md =
        atConnection.metaData as InboundConnectionMetadata;
    bool isAuthorized = await super.isAuthorized(md, atKey: atKey);
    if (!isAuthorized) {
      throw UnAuthorizedException(
          apkamUnauthorizedMsg(md.enrollmentId ?? 'primary', atKey));
    }

    // Being ALLOWED to rotate the legacy PKAM credential is not the same as
    // having proved you hold what you are installing — see
    // [verifyLegacyCredentialPossession]. Folded the keystore's own way, so
    // the comparison is against the string the store would hold rather than
    // against the spelling the wire happened to use.
    if (canonicalAtKey(atKey) == AtConstants.atPkamPublicKey) {
      await verifyLegacyCredentialPossession(verbParams, updateParams.value);
    }

    var keyType = AtKey.getKeyType(atKey, enforceNameSpace: false);
    switch (keyType) {
      case KeyType.selfKey:
      case KeyType.sharedKey:
      case KeyType.publicKey:
      case KeyType.reservedKey:
        break;
      case KeyType.privateKey:
      case KeyType.cachedPublicKey:
      case KeyType.cachedSharedKey:
      case KeyType.localKey:
      case KeyType.invalidKey:
        throw InvalidAtKeyException('You may not update keys of type $keyType');
    }

    var existingAtMetaData = await keyStore.getMeta(atKey);

    // An EXPIRED record is gone — a lookup of it already answers null — so it
    // must not shape the record that replaces it. Delete it outright rather
    // than teaching each reader below to look past it: once it is out of the
    // store, the cache-metadata validation, the immutability check and the
    // keystore's OWN retain-from-existing merge all see the same absence that
    // a reader already sees, instead of three places agreeing to pretend.
    //
    // Teaching the readers here would not have been enough. The keystore
    // re-reads the record for itself when it merges metadata
    // (AtMetadataBuilder), so an expired record would still have supplied
    // `immutable`, `createdAt` and `version` to the record replacing it — and
    // a create that asked for neither would be born immutable with an expiry
    // already in the past.
    //
    // Without this the server gave two different answers about whether a
    // record existed. It refused a create over an expired immutable record,
    // which made a ttl on such a record meaningless: the ttl expired the value
    // but the record stayed in the keystore until next expired-keys-cleanup
    // sweep, so a create-once interlock whose holder died blocked its own
    // atSign for longer than intended.
    //
    // skipCommit because nothing observable changes. Whenever we delete
    // expired records, we skip commit, because clients with sync'd copies will
    // also see the expiration and delete their local copy.
    //
    // Expiry only, and deliberately NOT SecondaryUtil.isActiveKey, which also
    // answers false before a record's ttb has elapsed. A not-yet-born record
    // still exists and must still refuse a second create; only an expired one
    // has stopped existing.
    if (existingAtMetaData != null && _hasExpired(existingAtMetaData)) {
      await keyStore.remove(atKey, skipCommit: true);
      existingAtMetaData = null;
    }

    var cacheRefreshMetaMap = hu.validateCacheMetadata(existingAtMetaData,
        updateParams.metadata!.ttr, updateParams.metadata!.ccd);
    updateParams.metadata!.ttr = cacheRefreshMetaMap[AtConstants.ttr];
    updateParams.metadata!.ccd = cacheRefreshMetaMap[AtConstants.ccd];

    //If ttr is set and atsign is not equal to currentAtSign, the key is
    //cached key.
    if (updateParams.metadata!.ttr != null &&
        updateParams.metadata!.ttr! > 0 &&
        sharedBy != null &&
        sharedBy != atSign) {
      throw IllegalArgumentException(
          'update verb but sharedBy ($sharedBy) is not current atSign ($atSign)');
    }

    _checkMaxLength(atKey);

    atData.metaData =
        AtMetaData.fromCommonsMetadata(updateParams.metadata!, atSign);

    // Enforce the immutable feature. An expired record has already been
    // dropped above, so this asks about a record that still exists.
    if (existingAtMetaData?.immutable == true) {
      throw IllegalStateException('Immutable records may not be updated');
    }
    atData.metaData = _unsetOrRetainMetadata(
      atData.metaData!,
      existingAtMetaData,
    );

    // Computed here, where existingAtMetaData reflects the expired-record
    // drop above — an expired record must not have its old expiry carried
    // forward into the record replacing it.
    return UpdatePreProcessResult(
        atKey,
        atData,
        effectiveAssertedTimestamps(updateParams.metadata!,
            existingAtMetaData));
  }

  /// Refuses a write of `privatekey:at_pkam_publickey` that does not prove
  /// possession of the key it is installing.
  ///
  /// The legacy PKAM credential is the one credential on the atSign whose
  /// public key lives outside any enrollment record, so it is the one
  /// credential a rotation could install without proving anything.
  /// `enroll:update` has demanded a verifying self-signature for every other
  /// enrollment's key since it existed; this is the same demand, in the same
  /// framing, for the one key that verb cannot reach.
  ///
  /// MEASURED consequence of not demanding it, in three arms differing only
  /// in the bytes stored at `at_pkam_publickey`: rotated to a well-formed key
  /// whose private half was never persisted, `primary` went on being counted
  /// as the atSign's surviving unexpiring root — the bar is a credential
  /// something can authenticate with, and a well-formed orphan passes it —
  /// while nothing could authenticate as it, so revoking the last root that
  /// really worked was permitted. Stored EMPTY it was not counted and the
  /// revoke was refused; left alone it was counted and authentication worked.
  /// The server cannot tell an orphan from a live key after the fact, so the
  /// demand has to be made at the moment of the write.
  ///
  /// BOOTSTRAP is exempt, and that exemption is what keeps onboarding
  /// working: when the atSign holds no housekeeping enrollment record there is
  /// nothing standing over the key, so an unusable value counts as nothing and
  /// mints nothing. Possession is proved later and by construction — the
  /// record is minted only by a legacy authentication that has already
  /// verified a signature against this key. Every other write is a ROTATION
  /// over a live identity and must prove itself, whoever is asking: a CRAM or
  /// owner connection included, since it can strand the atSign the same way.
  ///
  /// A legacy connection is authenticated AS `primary`, so the record always
  /// exists for the one enrollment that may write this key at all — the
  /// exemption is reachable only by an owner or CRAM connection on an atSign
  /// that has never minted the identity.
  ///
  /// THE CLIENT CONTRACT. The signature travels in the `update:json` document
  /// as `apkamPublicKeySignature`, alongside `signingAlgo`, spelled exactly as
  /// `enroll:update` spells them:
  ///
  /// ```
  /// update:json:{"atKey":"privatekey:at_pkam_publickey",
  ///              "value":"<new public key>",
  ///              "metadata":{...},
  ///              "signingAlgo":"rsa2048",
  ///              "apkamPublicKeySignature":"<base64>"}
  /// ```
  ///
  /// A client builds that by taking `UpdateParams.toJson()` — `metadata` must
  /// be a whole `Metadata` document, because `Metadata.fromJson` reads
  /// `isPublic` into a non-nullable bool — and adding the two fields to the
  /// map. They are read off the raw document rather than off `UpdateParams`,
  /// which drops what it does not model, the same way `metadata` relatives
  /// are already recovered here.
  ///
  /// The plain `update:privatekey:at_pkam_publickey <value>` form has no
  /// parameter that could carry a signature, so a rotation must use the JSON
  /// form; the plain form still serves the bootstrap. Nothing new is added to
  /// the `update` grammar for this, deliberately: a wire parameter this
  /// server read and no published builder could produce would be a fork of
  /// the protocol that only looks like an extension.
  ///
  /// [signingAlgo] is REQUIRED rather than defaulted. Every other APKAM key
  /// has its algorithm recorded on its enrollment; the legacy credential has
  /// none anywhere, because a legacy `pkam:` names its algorithm on the wire
  /// per connection — so there is nothing here to fall back on, and a wrong
  /// guess would install a key that cannot authenticate, which is the failure
  /// this method exists to prevent.
  ///
  /// REPLAY, stated because the shape invites the question. The signable is a
  /// CONSTANT — `primary|<value>|<signingAlgo>` carries no challenge, no
  /// session and no atSign — so an identical `update:json` document is
  /// replayable byte for byte, here and on any other atSign. That is
  /// deliberate, because this signature is not an authenticator and never
  /// stood between anyone and this key. `update` requires authentication, and
  /// the only connections authorised to write this key are an owner or CRAM
  /// connection, which carries no enrollment id, and a connection
  /// authenticated as the housekeeping enrollment; every other enrollment is
  /// refused before the value is looked at. Whoever replays a captured
  /// document is therefore already entitled to install a key of its own
  /// choosing, and can sign a fresh one with any key it holds. The single
  /// thing a captured document buys it is installing a key it does NOT hold —
  /// which is defeating this guard against itself.
  ///
  /// It differs from `enroll:update`'s equivalent in one respect, and the
  /// difference decides nothing. That signable names a server-issued
  /// enrollment id, unique to the atSign that issued it, so it is
  /// incidentally bound to one atSign; `primary` is the same literal on every
  /// atSign, so this one is not. Both are gated by the same authorisation, so
  /// neither binding is what stops a replay.
  ///
  /// The framing is therefore kept byte-identical to `enroll:update`'s rather
  /// than hardened with an atSign or a nonce. A client implements one rule for
  /// both rotations, `EnrollParams.apkamPublicKeySignature` publishes that
  /// rule, and a second framing that bought no security would be a footgun for
  /// the client author and nothing else.
  Future<void> verifyLegacyCredentialPossession(
      HashMap<String, String?> verbParams, dynamic value) async {
    final EnrollmentManager enMgr =
        AtSecondaryServerImpl.getInstance().enrollmentManager;
    if (!await keyStore.exists(enMgr
        .buildEnrollmentKey(EnrollmentManager.housekeepingEnrollmentId))) {
      // Bootstrap. See the doc comment: nothing stands over the key yet.
      return;
    }

    if (value is! String || value.isEmpty) {
      throw IllegalArgumentException(
          'update of ${AtConstants.atPkamPublicKey} requires a non-empty '
          'public key value');
    }

    final Map<String, dynamic> document;
    final String? json = verbParams['json'];
    try {
      document = json == null
          ? const {}
          : (jsonDecode(json) as Map).cast<String, dynamic>();
    } on FormatException {
      // getUpdateParams decoded the same string moments ago, so this cannot
      // be reached through the update verb; it is here so a malformed
      // document can never be read as "no signature was required".
      throw IllegalArgumentException(
          'update:json document does not parse as JSON');
    }

    final Object? signature = document['apkamPublicKeySignature'];
    final Object? signingAlgo = document['signingAlgo'];
    if (signature is! String ||
        signature.isEmpty ||
        signingAlgo is! String ||
        signingAlgo.isEmpty) {
      // An IllegalArgumentException rather than an UnAuthorizedException,
      // because the caller IS entitled to rotate this key and the request is
      // simply not the shape that can carry the proof. Keeping the two
      // distinguishable is what lets the authorisation tests assert that the
      // legacy carve-out still admits a legacy connection.
      throw IllegalArgumentException(
          'rotating ${AtConstants.atPkamPublicKey} requires proof that the '
          'sender holds the private half of the key it is installing: send '
          'the update as update:json carrying signingAlgo and '
          'apkamPublicKeySignature, a signature over '
          '"${EnrollmentManager.housekeepingEnrollmentId}|<new public key>|'
          '<signingAlgo>" made with the new key, as enroll:update requires of '
          'every other credential');
    }

    // Verified through ApkamSignatureVerifier, the same path `pkam:` and
    // `enroll:update` use, over the same three-part framing. A key that can
    // authenticate has to be installable, and a key installed here has to be
    // able to authenticate afterwards, so the two must agree byte for byte
    // about how a signature is framed.
    final String signable =
        '${EnrollmentManager.housekeepingEnrollmentId}|$value|$signingAlgo';
    final bool verified = await ApkamSignatureVerifier.verify(
      message: utf8.encode(signable),
      base64Signature: signature,
      publicKey: value,
      signingAlgo: ApkamSignatureVerifier.signingAlgoTypeOf(signingAlgo),
    );
    if (!verified) {
      throw UnAuthorizedException(
          'apkamPublicKeySignature does not verify against the '
          '${AtConstants.atPkamPublicKey} value being installed');
    }
  }

  /// Queues the auto-notification for a write that has already succeeded,
  /// reading the metadata back from the store so the notification carries
  /// exactly what was stored (client-asserted timestamps included).
  ///
  /// The caller still holds the per-key mutex, but delete and the TTL sweep
  /// take no mutex, so the record can vanish between the write and the
  /// read-back. The two outcomes are deliberately different:
  ///
  ///   * read-back returns NULL — the record was concurrently deleted, and
  ///     the deleter has queued (or is queueing) its own delete
  ///     notification. Queueing this update notification anyway could land
  ///     it AFTER the delete notification and resurrect the receiver's
  ///     cached key, so it is skipped, at warning.
  ///   * read-back THROWS — a transient store error; the record is
  ///     presumed present, so the notification is queued from the metadata
  ///     that was written rather than being dropped.
  ///
  /// A notify-queueing failure is logged at warning and NOT rethrown: the
  /// write happened, and the client's response must report it faithfully.
  Future<void> notifyAfterStore(
      HashMap<String, String?> verbParams,
      UpdateParams updateParams,
      UpdatePreProcessResult result) async {
    AtMetaData? stored;
    var readBackFailed = false;
    try {
      stored = await keyStore.getMeta(result.atKey);
    } catch (e) {
      readBackFailed = true;
      logger.warning('metadata read-back for ${result.atKey} failed ($e);'
          ' queueing the auto-notification from the written metadata');
    }
    if (stored == null && !readBackFailed) {
      logger.warning('auto-notification for ${result.atKey} skipped: the'
          ' record was deleted concurrently, and queueing an update'
          ' notification now could overtake the delete notification');
      return;
    }
    stored ??= result.atData.metaData;
    try {
      await notify(
          updateParams.sharedBy,
          updateParams.sharedWith,
          verbParams[AtConstants.atKey],
          updateParams.value,
          SecondaryUtil.getNotificationPriority(
              verbParams[AtConstants.priority]),
          stored!);
    } catch (e) {
      logger.warning('auto-notification for ${result.atKey} was not queued'
          ' ($e); the write itself succeeded');
    }
  }

  /// Puts back the "this request said nothing about it" state that commons
  /// `Metadata.fromJson` cannot represent.
  ///
  /// That parser turns an absent — or explicitly null — ttl/ttb/ttr into 0,
  /// and `Metadata.toJson` always writes the three, so a null makes the
  /// round trip as a 0. An `update:json` that never mentions expiry is then
  /// indistinguishable from one asking for `ttl:0`, which clears the
  /// record's expiry; the same goes for `ttb:0`, and for `ttr:0`, which
  /// stops the record being cached at the receiver.
  ///
  /// The metadata-fragment form of the same request leaves an unmentioned
  /// ttl/ttb/ttr null, and the retain-merge then keeps what the record
  /// already holds — so without this the two encodings of one request store
  /// different things, and only the json one moves an axis it never named.
  /// Read from the decoded map the DTO was built from, which still has the
  /// null.
  ///
  /// An at_commons that preserves the null makes this a no-op rather than a
  /// correction: it reads the same map to the same answer either way.
  void _restoreUnmentionedRelatives(Metadata? metadata, dynamic rawMetadata) {
    if (metadata == null || rawMetadata is! Map) {
      return;
    }
    if (rawMetadata[AtConstants.ttl] == null) {
      metadata.ttl = null;
    }
    if (rawMetadata[AtConstants.ttb] == null) {
      metadata.ttb = null;
    }
    if (rawMetadata[AtConstants.ttr] == null) {
      metadata.ttr = null;
    }
  }

  /// The timestamps this write must store faithfully: the request's own
  /// assertions ([metadata]'s createdAt/updatedAt/expiresAt/availableAt,
  /// parsed off the wire by [getUpdateParams] or, for `update:json`, by
  /// commons `Metadata.fromJson`) — plus, when the request says nothing at
  /// all about an expiry axis, the [existing] record's absolute for that
  /// axis, carried forward as an assertion so this write cannot move it.
  ///
  /// Without the carry, the retain-from-existing merge re-feeds the stored
  /// ttl/ttb into the metadata builder, which re-derives the absolute from
  /// now — so a write that never mentioned expiry would restart the expiry
  /// clock (and re-open a ttb record's not-yet-born window). Once set, an
  /// absolute moves only when a request speaks about its axis: a new
  /// assertion stores faithfully, a fresh ttl/ttb re-derives from now,
  /// ttl:0 clears the expiry, and ttb:0 re-stamps availableAt to now
  /// (immediate availability — the birth axis has no cleared state).
  ///
  /// A request that asserts an absolute WITHOUT supplying its relative
  /// (an eAt with no ttl, an aAt with no ttb) additionally asks the store
  /// to derive the relative the absolute implies — deriveTtl/deriveTtb on
  /// the returned assertions — replacing any ttl/ttb the retain-merge or
  /// the json coercion may have put on the write's metadata. That decision
  /// belongs here because only the request layer can tell a caller-
  /// supplied relative from a retained or coerced one.
  ///
  /// "Says nothing" is judged per axis on the request's own metadata,
  /// where absent means null. On the update:json path commons
  /// `Metadata.fromJson` coerces an absent ttl/ttb to 0, which is
  /// indistinguishable from an explicit 0 and therefore counts as the
  /// request speaking (ttl:0 clears expiry, as it always has) — except
  /// alongside an asserted absolute, where a 0 contradicts the absolute
  /// and counts as unsupplied, so the derivation wins on both encodings.
  ///
  /// Returns null when there is nothing to assert.
  AtAssertedTimestamps? effectiveAssertedTimestamps(
      Metadata metadata, AtMetaData? existing) {
    final expiryCarry = (metadata.expiresAt == null && metadata.ttl == null)
        ? existing?.expiresAt
        : null;
    final birthCarry = (metadata.availableAt == null && metadata.ttb == null)
        ? existing?.availableAt
        : null;
    if (metadata.createdAt == null &&
        metadata.updatedAt == null &&
        metadata.expiresAt == null &&
        metadata.availableAt == null &&
        expiryCarry == null &&
        birthCarry == null) {
      return null;
    }
    return AtAssertedTimestamps(
        createdAt: metadata.createdAt,
        updatedAt: metadata.updatedAt,
        expiresAt: metadata.expiresAt ?? expiryCarry,
        availableAt: metadata.availableAt ?? birthCarry,
        deriveTtl: metadata.expiresAt != null &&
            (metadata.ttl == null || metadata.ttl == 0),
        deriveTtb: metadata.availableAt != null &&
            (metadata.ttb == null || metadata.ttb == 0));
  }

  UpdateParams getUpdateParams(HashMap<String, String?> verbParams) {
    if (verbParams['json'] != null) {
      var jsonString = verbParams['json']!;
      Map jsonMap = jsonDecode(jsonString);
      final updateParams = UpdateParams.fromJson(jsonMap);
      _restoreUnmentionedRelatives(updateParams.metadata, jsonMap['metadata']);
      return updateParams;
    }
    var updateParams = UpdateParams();
    if (verbParams[AtConstants.atSign] != null) {
      updateParams.sharedBy =
          AtUtils.fixAtSign(verbParams[AtConstants.atSign]!);
    }
    if (verbParams[AtConstants.forAtSign] != null) {
      updateParams.sharedWith =
          AtUtils.fixAtSign(verbParams[AtConstants.forAtSign]!);
    }
    updateParams.atKey = verbParams[AtConstants.atKey];
    updateParams.value = verbParams[AtConstants.atValue];

    var metadata = Metadata();
    if (verbParams[AtConstants.ttl] != null) {
      metadata.ttl = AtMetadataUtil.validateTTL(verbParams[AtConstants.ttl]);
    }
    if (verbParams[AtConstants.ttb] != null) {
      metadata.ttb = AtMetadataUtil.validateTTB(verbParams[AtConstants.ttb]);
    }
    if (verbParams[AtConstants.ttr] != null) {
      metadata.ttr = hu.validateTTR(int.parse(verbParams[AtConstants.ttr]!));
    }
    if (verbParams[AtConstants.ccd] != null) {
      metadata.ccd =
          AtMetadataUtil.getBoolVerbParams(verbParams[AtConstants.ccd]);
    }
    // Caller-asserted timestamps (:cAt/:uAt/:eAt/:aAt) — the verb grammar
    // pins these to ISO 8601 UTC, so DateTime.parse cannot see a local time.
    if (verbParams[AtConstants.createdAt] != null) {
      metadata.createdAt = DateTime.parse(verbParams[AtConstants.createdAt]!);
    }
    if (verbParams[AtConstants.updatedAt] != null) {
      metadata.updatedAt = DateTime.parse(verbParams[AtConstants.updatedAt]!);
    }
    if (verbParams[WireParams.expiresAt] != null) {
      metadata.expiresAt = DateTime.parse(verbParams[WireParams.expiresAt]!);
    }
    if (verbParams[WireParams.availableAt] != null) {
      metadata.availableAt =
          DateTime.parse(verbParams[WireParams.availableAt]!);
    }
    metadata.dataSignature = verbParams[AtConstants.publicDataSignature];
    if (verbParams[AtConstants.isBinary] != null) {
      metadata.isBinary =
          AtMetadataUtil.getBoolVerbParams(verbParams[AtConstants.isBinary]);
    }
    if (verbParams[AtConstants.isEncrypted] != null) {
      metadata.isEncrypted =
          AtMetadataUtil.getBoolVerbParams(verbParams[AtConstants.isEncrypted]);
    }
    metadata.isPublic = verbParams[AtConstants.publicScopeParam] == 'public';
    metadata.sharedKeyEnc = verbParams[AtConstants.sharedKeyEncrypted];
    metadata.pubKeyCS = verbParams[AtConstants.sharedWithPublicKeyCheckSum];
    metadata.encoding = verbParams[AtConstants.encoding];
    metadata.encKeyName = verbParams[AtConstants.encryptingKeyName];
    metadata.encAlgo = verbParams[AtConstants.encryptingAlgo];
    metadata.ivNonce = verbParams[AtConstants.ivOrNonce];
    metadata.skeEncKeyName =
        verbParams[AtConstants.sharedKeyEncryptedEncryptingKeyName];
    metadata.skeEncAlgo =
        verbParams[AtConstants.sharedKeyEncryptedEncryptingAlgo];
    if (verbParams[AtConstants.sharedWithPublicKeyHash].isNotNullOrEmpty &&
        verbParams[AtConstants.sharedWithPublicKeyHashingAlgo]
            .isNotNullOrEmpty) {
      metadata.pubKeyHash = PublicKeyHash(
          verbParams[AtConstants.sharedWithPublicKeyHash]!,
          verbParams[AtConstants.sharedWithPublicKeyHashingAlgo]!);
    }
    if (verbParams[AtConstants.immutable] != null) {
      metadata.immutable =
          AtMetadataUtil.getBoolVerbParams(verbParams[AtConstants.immutable]);
    }
    // Arrives base64(JSON)-encoded on the wire; decodeAppMetadata also
    // maps an absent param (or the literal 'null') to null.
    try {
      metadata.appMetadata =
          Metadata.decodeAppMetadata(verbParams[AtConstants.appMetadata]);
    } on FormatException catch (e) {
      throw InvalidSyntaxException(
          'invalid ${AtConstants.appMetadata}: ${e.message}');
    }

    updateParams.metadata = metadata;

    if (updateParams.atKey == null || updateParams.atKey!.isEmpty) {
      throw InvalidSyntaxException('atKey.key not supplied');
    }

    if (updateParams.sharedBy != null &&
        updateParams.sharedBy!.isNotEmpty &&
        updateParams.sharedBy != atSign) {
      var message = 'Invalid update command - sharedBy atsign'
          ' ${AtUtils.fixAtSign(updateParams.sharedBy!)}'
          ' should be same as current atsign'
          ' $atSign';
      logger.warning(message);
      throw InvalidAtKeyException(message);
    }

    return updateParams;
  }

  Future<AtNotification?> notify(
      String? atSign,
      String? forAtSign,
      String? key,
      String? value,
      NotificationPriority priority,
      AtMetaData atMetaData) async {
    if (!_autoNotify) {
      return null;
    }
    if (forAtSign == null || forAtSign.isEmpty) {
      return null;
    }
    if (forAtSign.toAtsign() == atSign) {
      return null;
    }
    key = '$forAtSign:$key$atSign';
    int ttlInMillis =
        Duration(minutes: AtSecondaryConfig.notificationExpiryInMins)
            .inMilliseconds;

    var atNotification = (AtNotificationBuilder()
          ..fromAtSign = atSign
          ..toAtSign = forAtSign
          ..notification = key
          ..type = NotificationType.sent
          ..priority = priority
          ..opType = OperationType.update
          ..ttl = ttlInMillis
          ..atValue = value
          ..atMetaData = atMetaData)
        .build();

    await notificationManager.notify(atNotification);
    return atNotification;
  }

  /// Merges [newAtMetadata] (verb-supplied) with [existingAtMetadata] (what's
  /// in the keystore today), in place, and returns [newAtMetadata]:
  ///
  ///   * For each field, if the new value is `null`, take the existing value
  ///     (i.e. the verb didn't mention this field, so we keep what was there).
  ///   * For string-typed fields, the verb parser carries an explicit "unset"
  ///     intent as the literal string `'null'`. Translate that back to `null`.
  ///   * Otherwise, leave the new value as-is.
  ///
  /// This used to round-trip both metadata objects through `toJson()` and then
  /// `AtMetaData.fromJson()` to merge them generically, which allocated three
  /// 26-entry maps per update. The merge here mutates [newAtMetadata] directly
  /// and is allocation-free.
  AtMetaData _unsetOrRetainMetadata(
      AtMetaData newAtMetadata, AtMetaData? existingAtMetadata) {
    final existing = existingAtMetadata;

    // String fields. These can carry the 'null' sentinel because the verb
    // parser stores user-supplied String? values verbatim (so a `:foo:null`
    // verb param reaches us as the literal string 'null').
    newAtMetadata.createdBy =
        _mergeStringField(newAtMetadata.createdBy, existing?.createdBy);
    newAtMetadata.updatedBy =
        _mergeStringField(newAtMetadata.updatedBy, existing?.updatedBy);
    newAtMetadata.status =
        _mergeStringField(newAtMetadata.status, existing?.status);
    newAtMetadata.dataSignature =
        _mergeStringField(newAtMetadata.dataSignature, existing?.dataSignature);
    newAtMetadata.sharedKeyEnc =
        _mergeStringField(newAtMetadata.sharedKeyEnc, existing?.sharedKeyEnc);
    newAtMetadata.pubKeyCS =
        _mergeStringField(newAtMetadata.pubKeyCS, existing?.pubKeyCS);
    newAtMetadata.encoding =
        _mergeStringField(newAtMetadata.encoding, existing?.encoding);
    newAtMetadata.encKeyName =
        _mergeStringField(newAtMetadata.encKeyName, existing?.encKeyName);
    newAtMetadata.encAlgo =
        _mergeStringField(newAtMetadata.encAlgo, existing?.encAlgo);
    newAtMetadata.ivNonce =
        _mergeStringField(newAtMetadata.ivNonce, existing?.ivNonce);
    newAtMetadata.skeEncKeyName =
        _mergeStringField(newAtMetadata.skeEncKeyName, existing?.skeEncKeyName);
    newAtMetadata.skeEncAlgo =
        _mergeStringField(newAtMetadata.skeEncAlgo, existing?.skeEncAlgo);

    // DateTime / numeric / bool / PublicKeyHash fields are typed, so the
    // 'null' sentinel can never reach them — only retain-from-existing.
    newAtMetadata.createdAt ??= existing?.createdAt;
    newAtMetadata.updatedAt ??= existing?.updatedAt;
    newAtMetadata.availableAt ??= existing?.availableAt;
    newAtMetadata.expiresAt ??= existing?.expiresAt;
    newAtMetadata.refreshAt ??= existing?.refreshAt;

    newAtMetadata.version ??= existing?.version;
    newAtMetadata.ttl ??= existing?.ttl;
    newAtMetadata.ttb ??= existing?.ttb;
    newAtMetadata.ttr ??= existing?.ttr;

    newAtMetadata.isCascade ??= existing?.isCascade;
    newAtMetadata.isBinary ??= existing?.isBinary;
    newAtMetadata.isEncrypted ??= existing?.isEncrypted;
    newAtMetadata.immutable ??= existing?.immutable;

    newAtMetadata.pubKeyHash ??= existing?.pubKeyHash;
    // Like pubKeyHash, appMetadata is a typed (non-String) field, so
    // the 'null' unset sentinel cannot reach it — retain-only.
    newAtMetadata.appMetadata ??= existing?.appMetadata;

    return newAtMetadata;
  }

  /// Whether [metaData]'s record has passed its ttl.
  ///
  /// Compared on epoch milliseconds like [SecondaryUtil.isActiveKey], so the
  /// two agree about when a record dies even though they are asked different
  /// questions — that one folds in ttb and this one deliberately does not.
  static bool _hasExpired(AtMetaData metaData) {
    final expiresAt = metaData.expiresAt;
    if (expiresAt == null) return false;
    return expiresAt.toUtc().millisecondsSinceEpoch <
        DateTime.now().millisecondsSinceEpoch;
  }

  static String? _mergeStringField(String? newValue, String? existingValue) {
    if (newValue == null) return existingValue;
    if (newValue == 'null') return null;
    return newValue;
  }

  /// Certain keys created on one atsign server may be cached in another atsign server.
  /// Restrict key length to [_maxKeyLengthWithoutCached] if is not a cached key
  void _checkMaxLength(String key) {
    int maxLength =
        key.startsWith('cached:') ? maxKeyLength : maxKeyLengthWithoutCached;
    if (key.length > maxLength) {
      throw InvalidAtKeyException(
        'key length ${key.length} is greater than max allowed $maxLength chars',
      );
    }
  }
}

class UpdatePreProcessResult {
  String atKey;
  AtData atData;

  /// What the store must keep faithfully for this write — the request's
  /// own timestamp assertions plus the silent-write expiry carry. See
  /// [AbstractUpdateVerbHandler.effectiveAssertedTimestamps].
  AtAssertedTimestamps? assertedTimestamps;

  UpdatePreProcessResult(this.atKey, this.atData, this.assertedTimestamps);
}

/// Mutable holder for the per-key update mutex and its waiter count, so that
/// updating the count does not require allocating a new (Mutex, int) record.
class MutexRef {
  final Mutex mutex = Mutex();
  int waiters = 0;
}
