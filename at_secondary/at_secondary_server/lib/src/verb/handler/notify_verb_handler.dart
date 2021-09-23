import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

enum Type { sent, received }

class NotifyVerbHandler extends AbstractVerbHandler {
  static Notify notify = Notify();

  NotifyVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.notify) + ':') &&
      !command.startsWith('${getName(VerbEnum.notify)}:list') &&
      !command.startsWith('${getName(VerbEnum.notify)}:status') &&
      !command.startsWith('${getName(VerbEnum.notify)}:all');

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
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var cachedKeyCommitId;
    var atConnectionMetadata =
        atConnection.getMetaData() as InboundConnectionMetadata;
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
    var messageType = SecondaryUtil().getMessageType(verbParams[MESSAGE_TYPE]);
    var strategy = verbParams[STRATEGY];
    // If strategy is null, default it to strategy all.
    strategy ??= 'all';
    var notifier = verbParams[NOTIFIER];
    // If strategy latest, notifier is mandatory.
    // If notifier is null, throws InvalidSyntaxException.
    if (strategy == 'latest' && notifier == null) {
      throw InvalidSyntaxException(
          'For Strategy latest, notifier cannot be null');
    }
    // If strategy is ALL, default the notifier to system.
    if (strategy == 'all') {
      notifier ??= SYSTEM;
    }
    // If messageType is key, append the atSign to key. For messageType text,
    // atSign is not appended to the key.
    if (messageType == MessageType.key) {
      key = '$key$atSign';
    }
    if (forAtSign != null) {
      forAtSign = AtUtils.formatAtSign(forAtSign);
      key = '$forAtSign:$key';
    }
    var operation = verbParams[AT_OPERATION];
    var opType;
    if (operation != null) {
      opType = SecondaryUtil.getOperationType(operation);
    }
    try {
      ttl_ms = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
      ttb_ms = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
      if (verbParams[AT_TTR] != null) {
        ttr_ms = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]!));
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
        var notificationId = await NotificationUtil.storeNotification(
            forAtSign, atSign, key, NotificationType.received, opType,
            value: atValue);
        response.data = notificationId;
        return;
      }

      var atMetadata = AtMetaData();
      // If operation type is update, set value and ttr to cache a key
      // If operation type is delete, set ttr when not null to delete the cached key.
      if ((opType == OperationType.update &&
              ttr_ms != null &&
              atValue != null) ||
          (opType == OperationType.delete && ttr_ms != null)) {
        atMetadata.ttr = ttr_ms;
        atMetadata.isCascade = isCascade;
      }
      if (ttb_ms != null) {
        atMetadata.ttb = ttb_ms;
      }
      if (ttl_ms != null) {
        atMetadata.ttl = ttl_ms;
      }
      var atNotification = (AtNotificationBuilder()
            ..fromAtSign = atSign
            ..toAtSign = forAtSign
            ..notification = key
            ..opType = opType
            ..priority =
                SecondaryUtil().getNotificationPriority(verbParams[PRIORITY])
            ..atValue = atValue
            ..notifier = notifier
            ..strategy = strategy
            // For strategy latest, if depth is null, default it to 1. For strategy all, depth is not considered.
            ..depth = (_getIntParam(verbParams[LATEST_N]) != null)
                ? _getIntParam(verbParams[LATEST_N])
                : 1
            ..messageType = messageType
            ..notificationStatus = NotificationStatus.queued
            ..atMetaData = atMetadata
            ..type = NotificationType.sent)
          .build();
      var notificationId =
          await NotificationManager.getInstance().notify(atNotification);
      response.data = notificationId;
      return;
    }
    if (atConnectionMetadata.isPolAuthenticated) {
      logger.info('Storing the notification $key');
      await NotificationUtil.storeNotification(
          fromAtSign, forAtSign, key, NotificationType.received, opType,
          ttl_ms: ttl_ms, value: atValue);

      // If key is public, remove forAtSign from key.
      if (key!.contains('public:')) {
        var index = key.indexOf(':');
        key = key.substring(index + 1);
      }
      var notifyKey = '$CACHED:$key';
      if (operation == 'delete') {
        cachedKeyCommitId = await _removeCachedKey(notifyKey);
        //write the latest commit id to the StatsNotificationService
        await _writeStats(cachedKeyCommitId, operation);
        response.data = 'data:success';
        return;
      }

      var isKeyPresent = await keyStore!.get(notifyKey);
      var atMetadata;
      if (isKeyPresent != null) {
        atMetadata = await keyStore!.getMeta(notifyKey);
      }
      if (atValue != null && ttr_ms != null) {
        var metadata = AtMetadataBuilder(
                newAtMetaData: atMetadata,
                ttl: ttl_ms,
                ttb: ttb_ms,
                ttr: ttr_ms,
                ccd: isCascade)
            .build();
        cachedKeyCommitId =
            await _storeCachedKeys(key, metadata, atValue: atValue);
        //write the latest commit id to the StatsNotificationService
        await _writeStats(cachedKeyCommitId, operation);
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
        cachedKeyCommitId = await _updateMetadata(notifyKey, atMetaData);
        //write the latest commit id to the StatsNotificationService
        await _writeStats(cachedKeyCommitId, operation);
        response.data = 'data:success';
        return;
      }
      response.data = 'data:success';
    }
  }

  /// Create (or) update the cached key.
  /// key Key to cache.
  /// AtMetadata metadata of the key.
  /// atValue value of the key to cache.
  Future<int> _storeCachedKeys(String? key, AtMetaData? atMetaData,
      {String? atValue}) async {
    var notifyKey = '$CACHED:$key';
    var atData = AtData();
    atData.data = atValue;
    atData.metaData = atMetaData;
    logger.info('Cached $notifyKey');
    return await keyStore!.put(notifyKey, atData);
  }

  Future<int> _updateMetadata(String notifyKey, AtMetaData? atMetaData) async {
    logger.info('Updating the metadata of $notifyKey');
    return await keyStore!.putMeta(notifyKey, atMetaData);
  }

  ///Removes the cached key from the keystore.
  ///key Key to delete.
  Future<int?> _removeCachedKey(String key) async {
    var metadata = await keyStore!.getMeta(key);
    if (metadata != null && metadata.isCascade) {
      logger.info('Removed cached key $key');
      return await keyStore!.remove(key);
    }
  }

  int? _getIntParam(String? arg) {
    if (arg == null) {
      return null;
    }
    return int.parse(arg);
  }

  ///Sends the latest commitId to the StatsNotificationService
  Future<void> _writeStats(
      int? cachedKeyCommitId, String? operationType) async {
    try {
      if (cachedKeyCommitId != null) {
        await StatsNotificationService.getInstance().writeStatsToMonitor(
            latestCommitID: '$cachedKeyCommitId', operationType: operationType);
      }
    } on Exception catch (exception) {
      logger.info('Exception in writing stats ${exception.toString()}');
    }
  }
}
