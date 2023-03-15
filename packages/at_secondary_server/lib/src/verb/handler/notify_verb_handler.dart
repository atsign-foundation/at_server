import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:meta/meta.dart';
import 'package:mutex/mutex.dart';

enum Type { sent, received }

class NotifyVerbHandler extends AbstractVerbHandler {
  static Notify notify = Notify();

  NotifyVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  AtNotificationBuilder atNotificationBuilder = AtNotificationBuilder();

  Mutex processNotificationMutex = Mutex();

  /// A hashmap which holds the AtMetadata objects.
  /// The key represents if the notification text is encrypted or not
  /// The value represents the AtMetadata object where isEncrypted flag set to appropriate state.
  final Map<bool, AtMetaData> _atMetadataPool = {
    true: AtMetaData()
      ..isEncrypted = true
      ..createdBy = AtSecondaryServerImpl.getInstance().currentAtSign,
    false: AtMetaData()
      ..isEncrypted = false
      ..createdBy = AtSecondaryServerImpl.getInstance().currentAtSign
  };

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.notify)}:') &&
      !command.startsWith('${getName(VerbEnum.notify)}:list') &&
      !command.startsWith('${getName(VerbEnum.notify)}:status') &&
      !command.startsWith('${getName(VerbEnum.notify)}:all') &&
      !command.startsWith('${getName(VerbEnum.notify)}:remove') &&
      !command.startsWith('${getName(VerbEnum.notify)}:fetch');

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
    try {
      await processNotificationMutex.acquire();
      atNotificationBuilder.reset();
      var atConnectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      _validateNotifyVerbParams(verbParams);
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      // If '@' is missing before an atSign, the formatAtSign method prefixes '@' before atSign.
      verbParams[FOR_AT_SIGN] = AtUtils.formatAtSign(verbParams[FOR_AT_SIGN]);
      verbParams[AT_SIGN] =
          AtUtils.formatAtSign(verbParams[AT_SIGN]) ?? currentAtSign;
      logger.finer(
          'fromAtSign : ${atConnectionMetadata.fromAtSign} \n atSign : ${verbParams[AT_SIGN]} \n key : ${verbParams[AT_KEY]}');
      // When connection is authenticated, it indicates the sender side of the
      // the notification
      // If the currentAtSign and forAtSign are same, store the notification and return
      // Else, store the notification to keystore and notify to the toAtSign.
      if (atConnectionMetadata.isAuthenticated) {
        await _handleAuthenticatedConnection(
            currentAtSign, verbParams, response);
      }
      // When connection is polAuthenticated, it indicates the receiver side of the
      // the notification. Store the notification to the keystore.
      else if (atConnectionMetadata.isPolAuthenticated) {
        await _handlePolAuthenticatedConnection(
            verbParams, atConnectionMetadata, response);
      }
    } finally {
      processNotificationMutex.release();
    }
  }

  Future<void> _handlePolAuthenticatedConnection(
      HashMap<String, String?> verbParams,
      InboundConnectionMetadata atConnectionMetadata,
      Response response) async {
    logger.info('Storing the notification ${verbParams[AT_KEY]}');
    var atNotificationBuilder = _populateNotificationBuilder(verbParams,
        fromAtSign: atConnectionMetadata.fromAtSign!);
    // If messageType is key, atMetadata is set in "_populateNotificationBuilder"
    // When messageType is text, atNotificationBuilder.atMetadata fields are
    // not applicable except "atMetadata.isEncrypted".
    // So "atNotificationBuilder.atMetadata" will be overwritten
    // "atMetadata.isEncrypted" represents if the message is encrypted or not.
    if (atNotificationBuilder.messageType == MessageType.text) {
      atNotificationBuilder.atMetaData = _atMetadataPool[
          SecondaryUtil.getBoolFromString(verbParams[IS_ENCRYPTED])];
    }
    // Store the notification to the notification keystore.
    await NotificationUtil.storeNotification(atNotificationBuilder.build());
    OperationType operationType = getOperationType(verbParams[OPERATION]);
    // When Operation is update, cache key only when TTR is set.
    // So if TTR is null,  do nothing.
    // Also, If operation is delete removed the cached key - irrespective of TTR value.
    // So, If operation is not delete and TTR is null, return.
    if (operationType != OperationType.delete &&
        (_getTimeToRefresh(verbParams[AT_TTR]) == null)) {
      response.data = 'data:success';
      return;
    }
    // form a cached key
    String cachedNotificationKey =
        '$CACHED:${atNotificationBuilder.notification}';
    // If operationType is delete, remove the cached key only
    // when cascade delete is set to true
    int? cachedKeyCommitId;
    if (operationType == OperationType.delete) {
      cachedKeyCommitId = await _removeCachedKey(cachedNotificationKey);
      //write the latest commit id to the StatsNotificationService
      _writeStats(cachedKeyCommitId, operationType.name);
      response.data = 'data:success';
      return;
    }

    var isKeyPresent = keyStore.isKeyExists(cachedNotificationKey);
    AtMetaData? atMetadata;
    // If atValue is not null, store a cached key
    if (atNotificationBuilder.atValue != null) {
      // If the cached key is already present, get the existing metadata
      // and update the new metadata.
      if (isKeyPresent) {
        atMetadata = await keyStore.getMeta(cachedNotificationKey);
      }
      var metadata = AtMetadataBuilder(
              newAtMetaData: atNotificationBuilder.atMetaData,
              existingMetaData: atMetadata)
          .build();
      cachedKeyCommitId = await _storeCachedKeys(
          cachedNotificationKey, metadata,
          atValue: atNotificationBuilder.atValue);
      //write the latest commit id to the StatsNotificationService
      _writeStats(cachedKeyCommitId, operationType.name);
      response.data = 'data:success';
      return;
    }
    // The updateMetadata gets invoked via the update_meta verb to update the
    // cached key metadata.
    else if (isKeyPresent) {
      var atMetaData = atNotificationBuilder.atMetaData;
      cachedKeyCommitId =
          await _updateMetadata(cachedNotificationKey, atMetaData);
      //write the latest commit id to the StatsNotificationService
      _writeStats(cachedKeyCommitId, operationType.name);
      response.data = 'data:success';
      return;
    }
    response.data = 'data:success';
    return;
  }

  Future<void> _handleAuthenticatedConnection(currentAtSign,
      HashMap<String, String?> verbParams, Response response) async {
    // Check if the sharedBy atSign is currentAtSign. If yes allow to send notifications
    // else throw UnAuthorizedException
    if (!_isAuthorizedToSendNotification(verbParams[AT_SIGN], currentAtSign)) {
      throw UnAuthorizedException(
          '${verbParams[AT_SIGN]} is not authorized to send notification as $currentAtSign');
    }
    logger.finer(
        'currentAtSign : $currentAtSign, forAtSign : ${verbParams[FOR_AT_SIGN]}, atSign : ${verbParams[AT_SIGN]}');
    final atNotificationBuilder =
        _populateNotificationBuilder(verbParams, fromAtSign: currentAtSign);
    // If the currentAtSign and forAtSign are same, store the notification to keystore
    // and return
    if (currentAtSign == verbParams[FOR_AT_SIGN]) {
      // Since notification is stored to keystore, marking the notification
      // status as delivered
      atNotificationBuilder.notificationStatus = NotificationStatus.delivered;
      var notificationId = await NotificationUtil.storeNotification(
          atNotificationBuilder.build());
      response.data = notificationId;
      return;
    }
    // Send the notification to notification queue manager to notify to the forAtSign
    // and return the notification Id to the currentAtSign
    var notificationId = await NotificationManager.getInstance()
        .notify(atNotificationBuilder.build());
    response.data = notificationId;
    return;
  }

  /// Create (or) update the cached key.
  /// key Key to cache.
  /// AtMetadata metadata of the key.
  /// atValue value of the key to cache.
  Future<int> _storeCachedKeys(String? cachedKey, AtMetaData? atMetaData,
      {String? atValue}) async {
    var atData = AtData();
    atData.data = atValue;
    atData.metaData = atMetaData;
    logger.info('Cached $cachedKey :  $atMetaData');
    return await keyStore.put(cachedKey, atData);
  }

  Future<int> _updateMetadata(String cachedKey, AtMetaData? atMetaData) async {
    logger.info('Updating the metadata of $cachedKey');
    return await keyStore.putMeta(cachedKey, atMetaData);
  }

  ///Removes the cached key from the keystore.
  ///key Key to delete.
  Future<int?> _removeCachedKey(String cachedKey) async {
    var metadata = await keyStore.getMeta(cachedKey);
    print(metadata);
    if (metadata != null && metadata.isCascade) {
      logger.info('Removed cached key $cachedKey');
      return await keyStore.remove(cachedKey);
    } else {
      return null;
    }
  }

  int? _getIntParam(String? arg) {
    if (arg == null) {
      return null;
    }
    return int.parse(arg);
  }

  ///Sends the latest commitId to the StatsNotificationService
  void _writeStats(int? cachedKeyCommitId, String? operationType) {
    if (cachedKeyCommitId != null) {
      StatsNotificationService.getInstance().writeStatsToMonitor(
          latestCommitID: '$cachedKeyCommitId', operationType: operationType);
    }
  }

  /// Performs the validations on the notification verb params
  void _validateNotifyVerbParams(HashMap<String, String?> verbParams) {
    if (verbParams[STRATEGY] == 'latest' && verbParams[NOTIFIER] == null) {
      throw InvalidSyntaxException(
          'For Strategy latest, notifier cannot be null');
    }
  }

  /// Populates the [AtNotificationBuilder] object to construct the AtNotification
  /// object from the verbParams
  AtNotificationBuilder _populateNotificationBuilder(
      HashMap<String, String?> verbParams,
      // fromAtSign represents who sent the notification.
      // on sender, fromAtSign is same as currentAtSign and on receiver side,
      // If notification is of messageType "key" fromAtSign is fetched from verbparams
      // If notification is of messageType "text" fromAtSign is fetched from atConnectionMetadata.fromAtSign
      {String fromAtSign = ''}) {
    atNotificationBuilder = atNotificationBuilder
      ..toAtSign = AtUtils.formatAtSign(verbParams[FOR_AT_SIGN])
      ..fromAtSign = fromAtSign
      ..notificationDateTime = DateTime.now().toUtc()
      ..notification = _getFullFormedAtKey(
          getMessageType(verbParams[MESSAGE_TYPE]), verbParams)
      ..opType = getOperationType(verbParams[AT_OPERATION])
      ..priority = SecondaryUtil.getNotificationPriority(verbParams[PRIORITY])
      ..messageType = getMessageType(verbParams[MESSAGE_TYPE])
      ..notificationStatus = NotificationStatus.queued
      ..atMetaData = _getAtMetadataForNotification(verbParams)
      ..type = _getNotificationType(
          AtUtils.formatAtSign(verbParams[FOR_AT_SIGN])!,
          AtSecondaryServerImpl.getInstance().currentAtSign)
      ..ttl = getNotificationExpiryInMillis(verbParams[AT_TTL_NOTIFICATION])
      ..atValue = verbParams[AT_VALUE];
    atNotificationBuilder.strategy = _getStrategy(verbParams[STRATEGY]);
    atNotificationBuilder.notifier =
        _getNotifier(verbParams[NOTIFIER], _getStrategy(verbParams[STRATEGY]));
    // For strategy latest, if depth is null, default it to 1.
    // For strategy all, depth is not considered.
    atNotificationBuilder.depth = (_getIntParam(verbParams[LATEST_N]) != null)
        ? _getIntParam(verbParams[LATEST_N])
        : 1;
    if (verbParams[ID] != null && verbParams[ID]!.isNotEmpty) {
      atNotificationBuilder.id = verbParams[ID];
    }
    return atNotificationBuilder;
  }

  /// Gets the metadata from the verbParams
  AtMetaData _getAtMetadataForNotification(
      HashMap<String, String?> verbParams) {
    var atMetadata = AtMetaData()
      ..createdBy = AtSecondaryServerImpl.getInstance().currentAtSign;
    // If operation type is update, set value and ttr to cache a key
    // If operation type is delete, set ttr when not null to delete the cached key.
    int? ttrMillis = _getTimeToRefresh(verbParams[AT_TTR]);
    if (getOperationType(verbParams[AT_OPERATION]) == OperationType.update &&
            (ttrMillis != null && verbParams[AT_VALUE] != null) ||
        getOperationType(verbParams[AT_OPERATION]) == OperationType.delete &&
            ttrMillis != null) {
      atMetadata.ttr = ttrMillis;
      atMetadata.isCascade = _getCascadeDelete(verbParams[CCD], ttrMillis);
    }
    atMetadata.ttb = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
    atMetadata.ttl = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);

    if (verbParams[SHARED_KEY_ENCRYPTED] != null) {
      atMetadata.sharedKeyEnc = verbParams[SHARED_KEY_ENCRYPTED];
    }
    if (verbParams[SHARED_WITH_PUBLIC_KEY_CHECK_SUM] != null) {
      atMetadata.pubKeyCS = verbParams[SHARED_WITH_PUBLIC_KEY_CHECK_SUM];
    }
    atMetadata.isEncrypted = _getIsEncrypted(
        getMessageType(verbParams[MESSAGE_TYPE]),
        verbParams[AT_KEY]!,
        verbParams[IS_ENCRYPTED]);
    return atMetadata;
  }

  /// Returns the [OperationType] enum for the given string representation
  /// of operation type
  ///
  /// If null or empty string is passed, defaults to [OperationType.update]
  @visibleForTesting
  OperationType getOperationType(String? operationType) {
    return SecondaryUtil.getOperationType(operationType);
  }

  /// Returns the [MessageType] enum for the given string representation
  /// of message type
  ///
  /// If null or empty string is passed, defaults to [MessageType.key]
  @visibleForTesting
  MessageType getMessageType(String? messageType) {
    return SecondaryUtil.getMessageType(messageType);
  }

  /// Checks if the strategy is null or empty.
  /// If null or empty, returns default strategy - all
  ///
  /// The valid strategies are 'ALL' or 'LATEST' which is validated at the regex level
  String _getStrategy(String? strategy) {
    if (strategy == null || strategy.isEmpty) {
      strategy = 'all';
    }
    return strategy;
  }

  /// Returns the notifier for the given strategy
  ///
  /// If strategy is 'ALL', the default notifier is 'SYSTEM'
  ///
  /// If strategy is 'LATEST', the user have to populate the notifier; failing
  /// to populated notifier throws InvalidSyntaxException which is validated in
  /// 'validateNotifyVerbParams' method in this class.
  String _getNotifier(String? notifier, String strategy) {
    if ((notifier == null || notifier.isEmpty) && strategy == 'all') {
      notifier = SYSTEM;
    }
    return notifier!;
  }

  /// Returns the notification expiry duration in milliseconds
  ///
  /// Accepts the string representation and converts to integer
  ///
  /// Throws [InvalidSyntaxException] if a negative value or any string
  /// that contains other than numbers is passed
  ///
  /// If null or empty string is passed, defaults [AtSecondaryConfig.notificationExpiryInMins]
  @visibleForTesting
  int getNotificationExpiryInMillis(String? notificationExpiryDuration) {
    int notificationExpiryMillis = 0;
    if (notificationExpiryDuration == null ||
        notificationExpiryDuration == '0') {
      notificationExpiryMillis =
          Duration(minutes: AtSecondaryConfig.notificationExpiryInMins)
              .inMilliseconds;
      return notificationExpiryMillis;
    }
    return AtMetadataUtil.validateTTL(notificationExpiryDuration);
  }

  int? _getTimeToRefresh(String? ttr) {
    if (ttr == null || ttr.isEmpty) {
      return null;
    }
    return AtMetadataUtil.validateTTR(int.parse(ttr));
  }

  bool? _getCascadeDelete(String? cascadeDelete, int? ttrMillis) {
    if (ttrMillis != null) {
      return AtMetadataUtil.validateCascadeDelete(
          ttrMillis, AtMetadataUtil.getBoolVerbParams(cascadeDelete));
    }
    return false;
  }

  NotificationType _getNotificationType(String toAtSign, String currentAtSign) {
    if (toAtSign == currentAtSign) {
      return NotificationType.received;
    }
    return NotificationType.sent;
  }

  bool _getIsEncrypted(
      MessageType messageType, String key, String? isEncryptedStr) {
    if (messageType == MessageType.key && key.startsWith('public')) {
      return false;
    } else if (messageType == MessageType.text) {
      return SecondaryUtil.getBoolFromString(isEncryptedStr);
    } else {
      return true;
    }
  }

  String _getFullFormedAtKey(
      MessageType messageType, HashMap<String, String?> verbParam) {
    // If message type text do not concatenate fromAtSign (currentAtSign)
    if (messageType == MessageType.text) {
      return '${verbParam[FOR_AT_SIGN]}:${verbParam[AT_KEY]}';
    }
    // If message type is key, concatenate the atSign's
    // In the notify regex, although, "public" and "forAtSign" are mutually exclusive
    // for the "publicScope" named group.
    //
    // When notifying the public key's, the receiver atSign is not a part of the atKey
    // (which is not the case in the shared key Eg. "@receiverAtSign":something.namespace@senderAtSign").
    // So the receiver atSign has to mentioned explicitly. So command would look like
    // "@receiverAtSign:public:something.namespace@senderAtSign". So when regex is applied
    // the "publicScope" named group contains "@receiverAtSign" and "atKey" named group contains
    // "public:something.namespace".
    //
    if (verbParam[AT_KEY]!.startsWith('public')) {
      return '${verbParam[AT_KEY]}${verbParam[AT_SIGN]}';
    }
    return '${verbParam[FOR_AT_SIGN]}:${verbParam[AT_KEY]}${verbParam[AT_SIGN]}';
  }

  bool _isAuthorizedToSendNotification(String? sharedBy, String currentAtSign) {
    return sharedBy == currentAtSign;
  }
}
