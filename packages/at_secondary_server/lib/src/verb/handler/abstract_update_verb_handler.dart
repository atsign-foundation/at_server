import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/wire_param_names.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
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

  /// Static because UpdateVerbHandler and UpdateMetaVerbHandler must contend
  /// for the same mutexes.
  static final Map<String, MutexRef> _updateMutexes = {};

  Map<String, MutexRef> get updateMutexes => _updateMutexes;

  final String atSign;

  AbstractUpdateVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    this.notificationManager,
    this.atSign,
  );

  // Sets autoNotify from `config:set`, which the server subscribes to at
  // startup. `config:set` needs a connection authorised for the __config
  // namespace; it is not gated on the server's testing mode.
  static setAutoNotify(bool newState) {
    _autoNotify = newState;
  }

  String getDataStoreKey(UpdateParams updateParams) {
    final sharedWith = updateParams.sharedWith;
    final sharedBy = updateParams.sharedBy;
    var atKey = updateParams.atKey!;

    if (sharedWith != null && sharedWith.isNotEmpty) {
      atKey = '$sharedWith:$atKey';
    }
    if (sharedBy != null && sharedBy.isNotEmpty) {
      atKey = '$atKey$sharedBy';
    }
    if (updateParams.metadata!.isPublic) {
      atKey = 'public:$atKey';
    }

    return atKey;
  }

  String apkamUnauthorizedMsg(String enId, String key) =>
      'Connection with enrollment ID $enId'
      ' is not authorized to update key: $key';

  /// Authorises the write and builds the atKey, [AtData] and [AtMetaData] it
  /// will store, merging the existing record's metadata in wherever this
  /// request said nothing.
  ///
  /// The auto-notification is NOT queued here: the handler queues it via
  /// [notifyAfterStore] once the keystore write has succeeded, so the
  /// notification carries what was actually stored and a failed write queues
  /// nothing.
  Future<UpdatePreProcessResult> preProcess(
      Response response,
      HashMap<String, String?> verbParams,
      UpdateParams updateParams,
      InboundConnection atConnection) async {
    await super.processVerb(response, verbParams, atConnection);

    final sharedBy = updateParams.sharedBy;
    final value = updateParams.value;
    final atData = AtData();
    atData.data = value;

    String atKey = getDataStoreKey(updateParams);

    InboundConnectionMetadata md =
        atConnection.metaData as InboundConnectionMetadata;
    bool isAuthorized = await super.isAuthorized(md, atKey: atKey);
    if (!isAuthorized) {
      throw UnAuthorizedException(
          apkamUnauthorizedMsg(md.enrollmentId ?? 'primary', atKey));
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

    // An EXPIRED record is gone, since a lookup of it already answers null,
    // so it must not shape the record replacing it. Deleted outright rather
    // than skipped over by each reader below, because the keystore re-reads
    // the record for itself when it merges metadata (AtMetadataBuilder): an
    // expired one would still supply `immutable`, `createdAt` and `version`,
    // and a create that asked for neither would be born immutable with an
    // expiry already in the past.
    //
    // skipCommit because nothing observable changes: a client with a synced
    // copy sees the same expiry and drops its own.
    //
    // Expiry only, deliberately NOT SecondaryUtil.isActiveKey, which also
    // answers false before a record's ttb has elapsed. A not-yet-born record
    // still exists and must still refuse a second create.
    if (existingAtMetaData != null && _hasExpired(existingAtMetaData)) {
      await keyStore.remove(atKey, skipCommit: true);
      existingAtMetaData = null;
    }

    var cacheRefreshMetaMap = hu.validateCacheMetadata(existingAtMetaData,
        updateParams.metadata!.ttr, updateParams.metadata!.ccd);
    updateParams.metadata!.ttr = cacheRefreshMetaMap[AtConstants.ttr];
    updateParams.metadata!.ccd = cacheRefreshMetaMap[AtConstants.ccd];

    // A ttr on a key this atSign does not own would make it a cached key,
    // which `update` may not create.
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

    // An expired record was dropped above, so this asks about one that still
    // exists.
    if (existingAtMetaData?.immutable == true) {
      throw IllegalStateException('Immutable records may not be updated');
    }
    atData.metaData = _unsetOrRetainMetadata(
      atData.metaData!,
      existingAtMetaData,
    );

    // Computed here, where existingAtMetaData reflects the expired-record drop
    // above: an expired record must not carry its old expiry forward.
    return UpdatePreProcessResult(
        atKey,
        atData,
        effectiveAssertedTimestamps(updateParams.metadata!,
            existingAtMetaData));
  }

  /// Queues the auto-notification for a write that has already succeeded,
  /// reading the metadata back so the notification carries what was stored,
  /// client-asserted timestamps included.
  ///
  /// The caller holds the per-key mutex, but delete and the TTL sweep take
  /// none, so the record can vanish between write and read-back. The two
  /// outcomes differ deliberately: a NULL read-back means a concurrent
  /// delete, whose own notification this one could overtake and so resurrect
  /// the receiver's cached key, so it is skipped at warning; a THROWN
  /// read-back is a transient store error, so the notification is queued from
  /// the metadata that was written.
  ///
  /// A queueing failure is logged at warning and NOT rethrown: the write
  /// happened, and the client's response must say so.
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
  /// `Metadata.fromJson` cannot represent, reading it from the decoded map
  /// the DTO was built from.
  ///
  /// That parser turns an absent or explicitly null ttl/ttb/ttr into 0, so an
  /// `update:json` that never mentions expiry would be indistinguishable from
  /// one asking for `ttl:0`, which clears the record's expiry; likewise
  /// `ttb:0`, and `ttr:0`, which stops the receiver caching the record. The
  /// plain encoding of the same request leaves those null and the
  /// retain-merge keeps what the record holds, so without this the two
  /// spellings of one request store different things.
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
  /// assertions ([metadata]'s createdAt/updatedAt/expiresAt/availableAt),
  /// plus, when the request says nothing at all about an expiry axis, the
  /// [existing] record's absolute for that axis, carried forward so this
  /// write cannot move it.
  ///
  /// Without the carry the retain-from-existing merge re-feeds the stored
  /// ttl/ttb into the metadata builder, which re-derives the absolute from
  /// now, so a write that never mentioned expiry would restart the expiry
  /// clock and re-open a ttb record's not-yet-born window. Once set, an
  /// absolute moves only when a request speaks about its axis: ttl:0 clears
  /// the expiry, ttb:0 re-stamps availableAt to now, a fresh ttl/ttb
  /// re-derives from now, and a new assertion stores faithfully.
  ///
  /// A request asserting an absolute WITHOUT its relative (an eAt with no
  /// ttl, an aAt with no ttb) also asks the store to derive the relative that
  /// absolute implies, replacing any ttl/ttb the retain-merge or the json
  /// coercion put on the metadata. Only the request layer can tell a
  /// caller-supplied relative from a retained or coerced one.
  ///
  /// "Says nothing" is judged per axis on the request's own metadata. On the
  /// update:json path an absent ttl/ttb arrives coerced to 0, which counts as
  /// the request speaking, except alongside an asserted absolute, where the 0
  /// contradicts it and counts as unsupplied.
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

  /// The value charset the plain grammar pins: ` (?<value>.+)`, and Dart's
  /// `.` does not match a newline. A line-oriented protocol cannot carry a
  /// multi-line value, so a document that supplies one is refused rather
  /// than stored for something downstream to mis-frame.
  static final RegExp _grammarValue = RegExp(r'^.+$');

  UpdateParams getUpdateParams(HashMap<String, String?> verbParams) {
    if (verbParams['json'] != null) {
      var jsonString = verbParams['json']!;
      final UpdateParams updateParams;
      final Map jsonMap;
      try {
        jsonMap = jsonDecode(jsonString);
        updateParams = UpdateParams.fromJson(jsonMap);
      } on AtException {
        rethrow;
      } catch (e) {
        // A malformed document otherwise surfaces as a raw Dart TypeError or
        // FormatException and reaches the client as InternalServerError, so a
        // caller cannot tell its own bad request from a server fault. The
        // common case is a metadata map omitting isBinary/isEncrypted/
        // isPublic, which commons assigns into non-nullable bools.
        throw InvalidSyntaxException('invalid update:json document: $e');
      }
      _restoreUnmentionedRelatives(updateParams.metadata, jsonMap['metadata']);
      _validateJsonUpdateParams(updateParams);
      _validateUpdateParams(updateParams);
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
    // Caller-asserted timestamps (:cAt/:uAt/:eAt/:aAt): the verb grammar
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

    _validateUpdateParams(updateParams);

    return updateParams;
  }

  /// The checks that hold however the command was spelled: a key must have a
  /// name, and a write may not name another atSign as sharedBy inside this
  /// atSign's keystore.
  void _validateUpdateParams(UpdateParams updateParams) {
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
  }

  /// Holds a decoded `update:json` document to the bar the plain grammar
  /// enforces before a command reaches a handler: a non-empty single-line
  /// value, normalised atSigns, valid ttl/ttb/ttr, no public-and-shared key,
  /// and UTC asserted timestamps.
  ///
  /// It deliberately does NOT enforce the grammar's atKey charset; see the
  /// note at the head of the body.
  void _validateJsonUpdateParams(UpdateParams updateParams) {
    // The atKey CHARSET is deliberately not checked. `update:json` exists to
    // express keys the plain grammar cannot, a namespace-less `privatekey:`
    // key with an arbitrary suffix among them, so holding it to the grammar's
    // colon-free charset would remove a capability the server relies on. That
    // wider surface is governed by authorisation, `_decideRootKey` and the
    // key-type switch in [preProcess], not by syntax.
    final dynamic value = updateParams.value;
    if (value is! String || !_grammarValue.hasMatch(value)) {
      throw InvalidSyntaxException(
          'invalid value: update:json requires a non-empty, single-line'
          ' string, as the update grammar does');
    }

    // fixAtSign lowercases, prepends the '@', refuses a second '@' and strips
    // a trailing dotted domain, the normalisation the plain path applies
    // before anything compares atSigns. Without it a sharedBy of 'Alice' or
    // '@alice@evil' reaches the keystore verbatim and the identity check
    // below compares the wrong string.
    if (updateParams.sharedBy.isNotNullOrEmpty) {
      updateParams.sharedBy = AtUtils.fixAtSign(updateParams.sharedBy!);
    }
    if (updateParams.sharedWith.isNotNullOrEmpty) {
      updateParams.sharedWith = AtUtils.fixAtSign(updateParams.sharedWith!);
    }

    final Metadata? metadata = updateParams.metadata;
    if (metadata == null) {
      return;
    }
    if (metadata.ttl != null) {
      AtMetadataUtil.validateTTL(metadata.ttl.toString());
    }
    if (metadata.ttb != null) {
      AtMetadataUtil.validateTTB(metadata.ttb.toString());
    }
    if (metadata.ttr != null) {
      hu.validateTTR(metadata.ttr!);
    }

    // The grammar makes `public` and `@<forAtSign>` alternatives of one group,
    // so a plain command cannot say both. A record that is public AND shared
    // with one atSign has no meaning, and the two halves are read by
    // different code paths.
    if (metadata.isPublic == true && updateParams.sharedWith.isNotNullOrEmpty) {
      throw InvalidSyntaxException(
          'invalid update:json document: a key cannot be public and shared'
          ' with ${updateParams.sharedWith} at once');
    }

    // The grammar pins :cAt/:uAt/:eAt/:aAt to ISO-8601 with a trailing 'Z',
    // so a plain command cannot assert a local time. These are compared
    // against other atSigns' and ordered against the commit log, and a local
    // one silently shifts by the server's offset.
    for (final MapEntry<String, DateTime?> asserted in {
      'createdAt': metadata.createdAt,
      'updatedAt': metadata.updatedAt,
      'expiresAt': metadata.expiresAt,
      'availableAt': metadata.availableAt,
    }.entries) {
      if (asserted.value != null && !asserted.value!.isUtc) {
        throw InvalidSyntaxException(
            'invalid update:json document: ${asserted.key} must be UTC, as'
            ' the update grammar requires');
      }
    }
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

  /// Merges the keystore's [existingAtMetadata] into the verb-supplied
  /// [newAtMetadata], in place, and returns the latter.
  ///
  /// A null new value means the verb said nothing about the field, so the
  /// existing value is kept. On a string-typed field the verb parser carries
  /// an explicit "unset" as the literal `'null'`, which becomes null.
  AtMetaData _unsetOrRetainMetadata(
      AtMetaData newAtMetadata, AtMetaData? existingAtMetadata) {
    final existing = existingAtMetadata;

    // Only string fields can carry the 'null' sentinel, because the verb
    // parser stores user-supplied String? values verbatim.
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

    // Typed fields cannot receive the 'null' sentinel: retain-only.
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
    newAtMetadata.appMetadata ??= existing?.appMetadata;

    return newAtMetadata;
  }

  /// Whether [metaData]'s record has passed its ttl.
  ///
  /// Compared on epoch milliseconds like [SecondaryUtil.isActiveKey], so the
  /// two agree about when a record dies even though that one also folds in
  /// ttb and this one deliberately does not.
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

  /// Bounds the key length, allowing a cached key the extra room the
  /// `cached:` prefix takes ([maxKeyLength] vs [maxKeyLengthWithoutCached]).
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

  /// What the store must keep faithfully for this write: the request's own
  /// timestamp assertions plus the silent-write expiry carry. See
  /// [AbstractUpdateVerbHandler.effectiveAssertedTimestamps].
  AtAssertedTimestamps? assertedTimestamps;

  UpdatePreProcessResult(this.atKey, this.atData, this.assertedTimestamps);
}

/// The per-key update mutex and its waiter count. Mutable so that changing
/// the count does not allocate.
class MutexRef {
  final Mutex mutex = Mutex();
  int waiters = 0;
}
