import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
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

  AbstractUpdateVerbHandler(
      SecondaryKeyStore keyStore,
      StatsNotificationService statsNotificationService,
      this.notificationManager)
      : super(keyStore, statsNotificationService);

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
          ' ${AtUtils.formatAtSign(updateParams.sharedBy)}'
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

    // Get the key using verbParams (forAtSign, key, atSign)
    if (sharedWith != null && sharedWith.isNotEmpty) {
      atKey = '$sharedWith:$atKey';
    }
    if (sharedBy != null && sharedBy.isNotEmpty) {
      atKey = '$atKey$sharedBy';
    }
    // Append public: as prefix if key is public
    if (updateParams.metadata!.isPublic != null &&
        updateParams.metadata!.isPublic!) {
      atKey = 'public:$atKey';
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
    updateParams.metadata!.ttr = cacheRefreshMetaMap[AT_TTR];
    updateParams.metadata!.ccd = cacheRefreshMetaMap[CCD];

    //If ttr is set and atsign is not equal to currentAtSign, the key is
    //cached key.
    if (updateParams.metadata!.ttr != null &&
        updateParams.metadata!.ttr! > 0 &&
        sharedBy != null &&
        sharedBy != AtSecondaryServerImpl.getInstance().currentAtSign) {
      atKey = 'cached:$atKey';
    }

    atData.metaData = AtMetaData.fromCommonsMetadata(updateParams.metadata!);

    atData.metaData =
        _setNullOrExistingMetadata(atData.metaData!, existingAtMetaData);

    notify(
        sharedBy,
        sharedWith,
        verbParams[AT_KEY],
        value,
        SecondaryUtil.getNotificationPriority(verbParams[PRIORITY]),
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
    updateParams.sharedBy = AtUtils.formatAtSign(verbParams[AT_SIGN]);
    updateParams.sharedWith = AtUtils.formatAtSign(verbParams[FOR_AT_SIGN]);
    updateParams.atKey = verbParams[AT_KEY];
    updateParams.value = verbParams[AT_VALUE];

    var metadata = Metadata();
    metadata.isBinary = null;
    if (verbParams[AT_TTL] != null) {
      metadata.ttl = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
    }
    if (verbParams[AT_TTB] != null) {
      metadata.ttb = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
    }
    if (verbParams[AT_TTR] != null) {
      metadata.ttr = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]!));
    }
    if (verbParams[CCD] != null) {
      metadata.ccd = AtMetadataUtil.getBoolVerbParams(verbParams[CCD]);
    }
    metadata.dataSignature = verbParams[PUBLIC_DATA_SIGNATURE];
    if (verbParams[IS_BINARY] != null) {
      metadata.isBinary =
          AtMetadataUtil.getBoolVerbParams(verbParams[IS_BINARY]);
    }
    if (verbParams[IS_ENCRYPTED] != null) {
      metadata.isEncrypted =
          AtMetadataUtil.getBoolVerbParams(verbParams[IS_ENCRYPTED]);
    }
    metadata.isPublic = verbParams[PUBLIC_SCOPE_PARAM] == 'public';
    metadata.sharedKeyEnc = verbParams[SHARED_KEY_ENCRYPTED];
    metadata.pubKeyCS = verbParams[SHARED_WITH_PUBLIC_KEY_CHECK_SUM];
    metadata.encoding = verbParams[ENCODING];
    metadata.encKeyName = verbParams[ENCRYPTING_KEY_NAME];
    metadata.encAlgo = verbParams[ENCRYPTING_ALGO];
    metadata.ivNonce = verbParams[IV_OR_NONCE];
    metadata.skeEncKeyName =
        verbParams[SHARED_KEY_ENCRYPTED_ENCRYPTING_KEY_NAME];
    metadata.skeEncAlgo = verbParams[SHARED_KEY_ENCRYPTED_ENCRYPTING_ALGO];

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
  AtMetaData _setNullOrExistingMetadata(
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
}

class UpdatePreProcessResult {
  String atKey;
  AtData atData;

  UpdatePreProcessResult(this.atKey, this.atData);
}
