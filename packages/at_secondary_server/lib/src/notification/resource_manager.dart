import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Class that is responsible for sending the notifications.
class ResourceManager {
  static final logger = AtSignLogger('NotificationResourceManager');
  static final ResourceManager _singleton = ResourceManager._internal();

  bool _isProcessingQueue = false;

  bool get isProcessingQueue => _isProcessingQueue;

  bool _nudged = false;

  bool _started = false;

  static var maxRetries = AtSecondaryConfig.maxNotificationRetries;

  ResourceManager._internal();

  factory ResourceManager.getInstance() {
    return _singleton;
  }

  final NotifyConnectionsPool _notifyConnectionsPool =
      NotifyConnectionsPool.getInstance();

  int get outboundConnectionLimit => _notifyConnectionsPool.size;

  set outboundConnectionLimit(int ocl) => _notifyConnectionsPool.size = ocl;

  void start() {
    _started = true;
    logger.info('start() called');
    Future.delayed(Duration(milliseconds: 0)).then((value) {
      _schedule();
    });
  }

  void stop() {
    logger.info('stop() called');
    _started = false;
  }

  var quarantineDuration = AtSecondaryConfig.notificationQuarantineDuration;
  int notificationJobFrequency = AtSecondaryConfig.notificationJobFrequency;

  /// Ensures that notification processing starts immediately if it's not already
  void nudge() async {
    if (_started == false) {
      return;
    }
    _nudged = true;
    unawaited(_processNotificationQueue());
  }

  ///Runs for every configured number of seconds(5).
  Future<void> _schedule() async {
    if (_started == false) {
      return;
    }
    await _processNotificationQueue();
    var millisBetweenRuns = notificationJobFrequency * 1000;
    unawaited(Future.delayed(Duration(milliseconds: millisBetweenRuns))
        .then((value) => _schedule()));
  }

  Future<void> _processNotificationQueue() async {
    if (_started == false) {
      return;
    }

    if (_isProcessingQueue) {
      return;
    }
    _isProcessingQueue = true;
    _nudged = false;

    late Iterator notificationIterator;
    try {
      //1. Find the cap on the notifyConnectionsPool size
      var numberOfOutboundConnections = _notifyConnectionsPool.size;

      //2. Get the atsign on priority basis.
      var atSignIterator = AtNotificationMap.getInstance()
          .getAtSignToNotify(numberOfOutboundConnections);

      while (atSignIterator.moveNext()) {
        String atSign = atSignIterator.current;
        notificationIterator = QueueManager.getInstance().dequeue(atSign);
        //3. Connect to the atSign and send the notifications
        OutboundClient outboundClient;
        try {
          outboundClient = await _connect(atSign);
        } on ConnectionInvalidException catch (e) {
          var errorList = [];
          logger.warning('Connection failed for $atSign : ${e.toString()}');
          AtNotificationMap.getInstance().quarantineMap[atSign] =
              DateTime.now().add(Duration(seconds: quarantineDuration!));
          while (notificationIterator.moveNext()) {
            errorList.add(notificationIterator.current);
          }
          await _enqueueErrorList(errorList);
          continue;
        }
        await sendNotifications(atSign, outboundClient, notificationIterator);
      }
    } on Exception catch (ex, stackTrace) {
      logger.severe("_processNotificationQueue() caught exception $ex");
      logger.severe(stackTrace.toString());
    } finally {
      _isProcessingQueue = false;
      if (_nudged) {
        unawaited(Future.delayed(Duration(milliseconds: 0))
            .then((value) => _processNotificationQueue()));
      }
    }
  }

  /// Establish an outbound connection to [toAtSign]
  /// Returns OutboundClient, if connection is successful.
  /// Throws [ConnectionInvalidException] for any exceptions
  Future<OutboundClient> _connect(String toAtSign) async {
    var outBoundClient = _notifyConnectionsPool.get(toAtSign);
    try {
      if (!outBoundClient.isHandShakeDone) {
        var isConnected = await outBoundClient.connect();
        logger.finest('outBoundClient.connect() result: $isConnected');
      }
      return outBoundClient;
    } on Exception catch (e) {
      var msg = 'Connection failed to $toAtSign with exception: $e';
      logger.warning(msg);
      outBoundClient.inboundConnection.getMetaData().isClosed = true;
      throw ConnectionInvalidException(msg);
    }
  }

  /// Send the Notification to [atNotificationList.toAtSign]
  @visibleForTesting
  Future<void> sendNotifications(
      String atSign, OutboundClient outBoundClient, Iterator iterator) async {
    // ignore: prefer_typing_uninitialized_variables
    var notifyResponse, atNotification;
    var errorList = [];
    // For list of notifications, iterate on each notification and process the notification.
    try {
      while (iterator.moveNext()) {
        atNotification = iterator.current;
        var notifyCommandBody = prepareNotifyCommandBody(atNotification);
        notifyResponse = await outBoundClient.notify(notifyCommandBody);
        await _notifyResponseProcessor(
            notifyResponse, atNotification, errorList);
      }
      if (QueueManager.getInstance().numQueued(atSign) == 0) {
        // All notifications for this atSign have been cleared; we can remove the waitTimeEntry for this atSign
        AtNotificationMap.getInstance().removeWaitTimeEntry(atSign);
      }
    } catch (e) {
      logger.severe(
          'Exception in processing the notification ${atNotification.id} : ${e.toString()}');
      errorList.add(atNotification);
      while (iterator.moveNext()) {
        errorList.add(iterator.current);
      }
    } finally {
      //1. Adds errored notifications back to queue.
      await _enqueueErrorList(errorList);
    }
  }

  /// If the notification response is success, marks the status as [NotificationStatus.delivered]
  /// Else, marks the notification status as [NotificationStatus.queued] and reduce the priority and add back to queue.
  Future<void> _notifyResponseProcessor(
      String? response, AtNotification? atNotification, List errorList) async {
    // If response is 'data:success', update the notification status to delivered and
    // add update the key in notificationKeyStore.
    if (response == 'data:success') {
      atNotification?.notificationStatus = NotificationStatus.delivered;
      await AtNotificationKeystore.getInstance()
          .put(atNotification?.id, atNotification);
    } else {
      errorList.add(atNotification);
    }
  }

  /// Prepares the notification command
  /// Accepts [AtNotification]
  @visibleForTesting
  String prepareNotifyCommandBody(AtNotification atNotification) {
    // [gkc] I really don't like that the command string is being built from
    // the end backwards to the start; it has confused me every time I've
    // looked at this code.
    String commandBody;
    commandBody = '${atNotification.notification}';
    if (atNotification.atValue != null) {
      commandBody = '$commandBody:${atNotification.atValue}';
    }
    var atMetaData = atNotification.atMetadata;
    if (atMetaData != null) {
      if (atNotification.atMetadata!.skeEncAlgo != null) {
        commandBody =
            '$SHARED_KEY_ENCRYPTED_ENCRYPTING_ALGO:${atNotification.atMetadata!.skeEncAlgo}:$commandBody';
      }
      if (atNotification.atMetadata!.skeEncKeyName != null) {
        commandBody =
            '$SHARED_KEY_ENCRYPTED_ENCRYPTING_KEY_NAME:${atNotification.atMetadata!.skeEncKeyName}:$commandBody';
      }
      if (atNotification.atMetadata!.ivNonce != null) {
        commandBody =
            '$IV_OR_NONCE:${atNotification.atMetadata!.ivNonce}:$commandBody';
      }
      if (atNotification.atMetadata!.encAlgo != null) {
        commandBody =
            '$ENCRYPTING_ALGO:${atNotification.atMetadata!.encAlgo}:$commandBody';
      }
      if (atNotification.atMetadata!.encKeyName != null) {
        commandBody =
            '$ENCRYPTING_KEY_NAME:${atNotification.atMetadata!.encKeyName}:$commandBody';
      }
      if (atNotification.atMetadata!.pubKeyCS != null) {
        commandBody =
            '$SHARED_WITH_PUBLIC_KEY_CHECK_SUM:${atNotification.atMetadata!.pubKeyCS}:$commandBody';
      }
      if (atNotification.atMetadata!.sharedKeyEnc != null) {
        commandBody =
            '$SHARED_KEY_ENCRYPTED:${atNotification.atMetadata!.sharedKeyEnc}:$commandBody';
      }
      if (atNotification.atMetadata!.isEncrypted != null &&
          atNotification.atMetadata!.isEncrypted == true) {
        commandBody = '$IS_ENCRYPTED:true:$commandBody';
      }
      if (atMetaData.ttr != null) {
        commandBody =
            'ttr:${atMetaData.ttr}:ccd:${atMetaData.isCascade}:$commandBody';
      }
      if (atMetaData.ttb != null) {
        commandBody = 'ttb:${atMetaData.ttb}:$commandBody';
      }
      if (atMetaData.ttl != null) {
        commandBody = 'ttl:${atMetaData.ttl}:$commandBody';
      }
    }
    if (atNotification.ttl != null) {
      commandBody = 'ttln:${atNotification.ttl}:$commandBody';
    }

    commandBody = 'notifier:${atNotification.notifier}:$commandBody';
    commandBody =
        'messageType:${atNotification.messageType.toString().split('.').last}:$commandBody';
    if (atNotification.opType != null) {
      commandBody =
          '${atNotification.opType.toString().split('.').last}:$commandBody';
    }
    // prepending id to the notify command.
    commandBody = 'id:${atNotification.id}:$commandBody';
    return commandBody;
  }

  ///Adds the errored notifications back to queue.
  Future<void> _enqueueErrorList(List errorList) async {
    if (errorList.isEmpty) {
      return;
    }
    var iterator = errorList.iterator;
    while (iterator.moveNext()) {
      var atNotification = iterator.current;
      // Update the status to errored and persist the notification to keystore.
      atNotification?.notificationStatus = NotificationStatus.errored;
      await AtNotificationKeystore.getInstance()
          .put(atNotification?.id, atNotification);
      // If number retries are equal to maximum number of notifications, notifications are not further processed
      // hence remove entries from waitTimeMap and quarantineMap
      // TODO This should only be done when *all* of the pending notifications for this atSign have reached maxRetries
      if (atNotification.retryCount >= maxRetries) {
        AtNotificationMap.getInstance()
            .removeWaitTimeEntry(atNotification.toAtSign);
        AtNotificationMap.getInstance()
            .removeQuarantineEntry(atNotification.toAtSign);
        logger.warning(
            'Failed to notify ${atNotification.id} from ${atNotification.fromAtSign} to ${atNotification.toAtSign}. Maximum retries ($maxRetries) reached');
        continue;
      }
      logger.info('Retrying to notify: ${atNotification.id}'
          ' from ${atNotification.fromAtSign} to ${atNotification.toAtSign}.'
          ' Retry count: ${atNotification.retryCount}');
      QueueManager.getInstance().enqueue(atNotification);
    }
  }

  //setter to set maxNotificationRetries value from dynamic server config "config:set".
  //only works when testingMode is set to true
  void setMaxRetries(int newValue) {
    maxRetries = newValue;
  }
}
