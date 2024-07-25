import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/change_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';

abstract class AbstractUpdateVerbHandler extends ChangeVerbHandler {
  static bool _autoNotify = AtSecondaryConfig.autoNotify;
  late final NotificationManager notificationManager;
  static const int maxKeyLength = 255;
  static const int maxKeyLengthWithoutCached = 248;

  AbstractUpdateVerbHandler(
    super.keyStore,
    super.statsNotificationService,
    this.notificationManager,
  );

  //setter to set autoNotify value from dynamic server config "config:set".
  //only works when testingMode is set to true
  static setAutoNotify(bool newState) {
    if (AtSecondaryConfig.testingMode) {
      _autoNotify = newState;
    }
  }

  Future<UpdatePreProcessResult> preProcessAndNotify(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    // Sets Response bean to the response bean in ChangeVerbHandler
    await super.processVerb(response, verbParams, atConnection);

    var updateParams = getUpdateParams(verbParams);
    if (updateParams.atKey == null || updateParams.atKey!.isEmpty) {
      throw InvalidSyntaxException('atKey.key not supplied');
    }

    if (updateParams.sharedBy != null &&
        updateParams.sharedBy!.isNotEmpty &&
        updateParams.sharedBy !=
            AtSecondaryServerImpl.getInstance().currentAtSign) {
      var message = 'Invalid update command - sharedBy atsign'
          ' ${AtUtils.fixAtSign(updateParams.sharedBy!)}'
          ' should be same as current atsign'
          ' ${AtSecondaryServerImpl.getInstance().currentAtSign}';
      logger.warning(message);
      throw InvalidAtKeyException(message);
    }

    // Get the key and update the value
    final sharedWith = updateParams.sharedWith;
    final sharedBy = updateParams.sharedBy;
    var atKey = updateParams.atKey!;
    final value = updateParams.value;
    final atData = AtData();
    atData.data = value;

    bool isAuthorized = true; // for legacy clients allow access by default

    InboundConnectionMetadata inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;

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
    isAuthorized =
        await super.isAuthorized(inboundConnectionMetadata, atKey: atKey);
    if (!isAuthorized) {
      throw UnAuthorizedException(
          'Connection with enrollment ID ${inboundConnectionMetadata.enrollmentId}'
          ' is not authorized to update key: ${atKey.toString()}');
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
    var cacheRefreshMetaMap = validateCacheMetadata(existingAtMetaData,
        updateParams.metadata!.ttr, updateParams.metadata!.ccd);
    updateParams.metadata!.ttr = cacheRefreshMetaMap[AtConstants.ttr];
    updateParams.metadata!.ccd = cacheRefreshMetaMap[AtConstants.ccd];

    //If ttr is set and atsign is not equal to currentAtSign, the key is
    //cached key.
    if (updateParams.metadata!.ttr != null &&
        updateParams.metadata!.ttr! > 0 &&
        sharedBy != null &&
        sharedBy != AtSecondaryServerImpl.getInstance().currentAtSign) {
      atKey = 'cached:$atKey';
    }

    _checkMaxLength(atKey);

    atData.metaData = AtMetaData.fromCommonsMetadata(updateParams.metadata!);

    atData.metaData =
        _unsetOrRetainMetadata(atData.metaData!, existingAtMetaData);

    notify(
        sharedBy,
        sharedWith,
        verbParams[AtConstants.atKey],
        value,
        SecondaryUtil.getNotificationPriority(verbParams[AtConstants.priority]),
        atData.metaData!);

    return UpdatePreProcessResult(atKey, atData);
  }

  UpdateParams getUpdateParams(HashMap<String, String?> verbParams) {
    if (verbParams['json'] != null) {
      var jsonString = verbParams['json']!;
      Map jsonMap = jsonDecode(jsonString);
      return UpdateParams.fromJson(jsonMap);
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
      metadata.ttr =
          AtMetadataUtil.validateTTR(int.parse(verbParams[AtConstants.ttr]!));
    }
    if (verbParams[AtConstants.ccd] != null) {
      metadata.ccd =
          AtMetadataUtil.getBoolVerbParams(verbParams[AtConstants.ccd]);
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

    updateParams.metadata = metadata;
    return updateParams;
  }

  dynamic notify(String? atSign, String? forAtSign, String? key, String? value,
      NotificationPriority priority, AtMetaData atMetaData) async {
    if (!_autoNotify) {
      return;
    }
    if (forAtSign == null || forAtSign.isEmpty) {
      return;
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

    unawaited(notificationManager.notify(atNotification));
    return atNotification;
  }

  /// If metadata contains "null" string, then reset the metadata. So set it to null
  /// If metadata contains null (null object), then fetch the existing metadata.If
  /// existing metadata value is not null, set it the current AtMetaData obj.
  AtMetaData _unsetOrRetainMetadata(
      AtMetaData newAtMetadata, AtMetaData? existingAtMetadata) {
    if (existingAtMetadata == null) {
      return newAtMetadata;
    }
    var atMetaDataJson = newAtMetadata.toJson();
    var existingAtMetaDataJson = existingAtMetadata.toJson();
    atMetaDataJson.forEach((key, value) {
      switch (value) {
        // If command does not contains the attributes of a metadata, then regex named
        // group, inserts null. For a key, if an attribute has a value in previously,
        // fetch the value and update it.
        case null:
          if (existingAtMetaDataJson[key] != null) {
            atMetaDataJson[key] = existingAtMetaDataJson[key];
          }
          break;
        // In the command, if an attribute is explicitly set to null, then verbParams
        // contains String value "null". Then reset the metadata. So, set it to null
        case 'null':
          atMetaDataJson[key] = null;
          break;
      }
    });
    return AtMetaData.fromJson(atMetaDataJson);
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

  UpdatePreProcessResult(this.atKey, this.atData);
}
