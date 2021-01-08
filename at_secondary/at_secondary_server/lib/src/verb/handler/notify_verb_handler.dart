import 'dart:collection';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';

enum Type { sent, received }

class NotifyVerbHandler extends AbstractVerbHandler {
  static Notify notify = Notify();

  NotifyVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.notify) + ':') &&
          !command.contains('list');

  @override
  Verb getVerb() {
    return notify;
  }

  /// Throws an [SecondaryNotFoundException] if unable to establish connection to another secondary
  /// Throws an [UnAuthorizedException] if notify if invoked with handshake=true and without a successful handshake
  ///  Throws an [notifyException] if there is exception during notify operation
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    InboundConnectionMetadata atConnectionMetadata = atConnection.getMetaData();
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var ttl_ms;
    var ttb_ms;
    var ttr_ms;
    var isCascade;
    var forAtSign = verbParams[FOR_AT_SIGN];
    var atSign = verbParams[AT_SIGN];
    var atValue = verbParams[AT_VALUE];
    atSign = AtUtils.formatAtSign(atSign);
    var key = verbParams[AT_KEY];
    key = '${key}${atSign}';
    if (forAtSign != null) {
      forAtSign = AtUtils.formatAtSign(forAtSign);
      key = '${forAtSign}:${key}';
    }
    var operation = verbParams[AT_OPERATION];
    var opType;
    if (operation != null) {
      opType =
      (operation == 'update') ? OperationType.update : OperationType.delete;
    }
    try {
      ttl_ms = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
      ttb_ms = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
      if (verbParams[AT_TTR] != null) {
        ttr_ms = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]));
      }
      isCascade = AtMetadataUtil.validateCascadeDelete(
          ttr_ms, AtMetadataUtil.getBoolVerbParams(verbParams[CCD]));
    } on InvalidSyntaxException {
      rethrow;
    }
    logger.finer(
        'fromAtSign : $fromAtSign \n atSign : ${atSign.toString()} \n key : $key');
    // Connection is authenticated and the currentAtSign is not atSign
    // notify secondary of atSign for the key
    if (atConnectionMetadata.isAuthenticated) {
      logger.finer(
          'currentAtSign : $currentAtSign, forAtSign : $forAtSign, atSign : $atSign');
      if (currentAtSign == forAtSign) {
        await NotificationUtil.storeNotification(atConnection, fromAtSign,
            forAtSign, key, NotificationType.received, opType,
            ttl_ms: ttl_ms);
        response.data = 'data:success';
        return;
      }
      await NotificationUtil.storeNotification(atConnection, fromAtSign,
          forAtSign, key, NotificationType.sent, opType,
          ttl_ms: ttl_ms);
      if (ttr_ms != null) {
        key = '$AT_TTR:$ttr_ms:$CCD:$isCascade:$key:$atValue';
      }
      if (ttb_ms != null) {
        key = '$AT_TTB:$ttb_ms:$key';
      }
      if (ttl_ms != null) {
        key = '$AT_TTL:$ttl_ms:$key';
      }
      if (operation != null) {
        key = '${operation}:${key}';
      }
      await NotificationUtil.sendNotification(forAtSign, atConnection, key);
      response.data = 'data:success';
      return;
    }
    if (atConnectionMetadata.isPolAuthenticated) {
      await NotificationUtil.storeNotification(atConnection, fromAtSign,
          forAtSign, key, NotificationType.received, opType,
          ttl_ms: ttl_ms, value: atValue);

      var notifyKey = '$CACHED:$key';
      if (operation == 'delete') {
        await _removeCachedKey(notifyKey);
        response.data = 'data:success';
        return;
      }

      var isKeyPresent = await keyStore.get(notifyKey);
      var atMetadata;
      if (isKeyPresent != null) {
        atMetadata = await keyStore.getMeta(notifyKey);
      }
      if (atValue != null && ttr_ms != null) {
        var metadata = AtMetadataBuilder(
            newAtMetaData: atMetadata,
            ttl: ttl_ms,
            ttb: ttb_ms,
            ttr: ttr_ms,
            ccd: isCascade)
            .build();
        await _storeCachedKeys(key, metadata, atValue: atValue);
        response.data = 'data:success';
        return;
      }

      // Update metadata only if key is cached.
      if (isKeyPresent != null) {
        var atMetaData = AtMetadataBuilder(
            newAtMetaData: atMetadata,
            ttl: ttl_ms,
            ttb: ttb_ms,
            ttr: ttr_ms,
            ccd: isCascade)
            .build();
        await _updateMetadata(notifyKey, atMetaData);
        response.data = 'data:success';
        return;
      }
    }
  }

  /// Create (or) update the cached key.
  /// key Key to cache.
  /// AtMetadata metadata of the key.
  /// atValue value of the key to cache.
  void _storeCachedKeys(String key, AtMetaData atMetaData,
      {String atValue}) async {
    var notifyKey = '$CACHED:$key';
    var atData = AtData();
    atData.data = atValue;
    atData.metaData = atMetaData;
    await keyStore.put(notifyKey, atData);
  }

  void _updateMetadata(String notifyKey, AtMetaData atMetaData) async {
    await keyStore.putMeta(notifyKey, atMetaData);
  }

  ///Removes the cached key from the keystore.
  ///key Key to delete.
  void _removeCachedKey(String key) async {
    var metadata = await keyStore.getMeta(key);
    if (metadata != null && metadata.isCascade) {
      await keyStore.remove(key);
    }
  }
}
