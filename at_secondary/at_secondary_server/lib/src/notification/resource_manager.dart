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
  static final ResourceManager _singleton = ResourceManager._internal();
  bool _isProcessingQueue = false;

  bool get isProcessingQueue => _isProcessingQueue;

  bool _isStarted = false;
  bool get isStarted => _isStarted;

  bool _nudged = false;

  static var maxRetries = AtSecondaryConfig.maxNotificationRetries;

  ResourceManager._internal();

  factory ResourceManager.getInstance() {
    return _singleton;
  }

  void init(int outboundConnectionLimit) {
    NotifyConnectionsPool.getInstance().init(outboundConnectionLimit);
    _isStarted = true;
    Future.delayed(Duration(milliseconds: 0)).then((value) {
      _schedule();
    });
  }

  final logger = AtSignLogger('NotificationResourceManager');
  var quarantineDuration = AtSecondaryConfig.notificationQuarantineDuration;
  int notificationJobFrequency = AtSecondaryConfig.notificationJobFrequency;

  /// Ensures that notification processing starts immediately if it's not already
  void nudge() async {
    _nudged = true;
    _processNotificationQueue();
  }

  ///Runs for every configured number of seconds(5).
  Future<void> _schedule() async {
    await _processNotificationQueue();
    var millisBetweenRuns = notificationJobFrequency * 1000;
    Future.delayed(Duration(milliseconds: millisBetweenRuns))
        .then((value) => _schedule());
  }

  Future<void> _processNotificationQueue() async {
    if (_isProcessingQueue) {
      return;
    }
    _isProcessingQueue = true;
    _nudged = false;
    String? atSign;
    late Iterator notificationIterator;
    try {
      //1. Check how many outbound connections are free.
      var N = NotifyConnectionsPool.getInstance().size;

      //2. Get the atsign on priority basis.
      var atSignIterator = AtNotificationMap.getInstance().getAtSignToNotify(N);

      while (atSignIterator.moveNext()) {
        atSign = atSignIterator.current;
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
        await sendNotifications(atSign!, outboundClient, notificationIterator);
      }
    } on Exception catch (ex, stackTrace) {
      logger.severe("_processNotificationQueue() caught exception $ex");
      logger.severe(stackTrace.toString());
    } finally {
      _isProcessingQueue = false;
      if (_nudged) {
        Future.delayed(Duration(milliseconds: 0))
            .then((value) => _processNotificationQueue());
      }
    }
  }

  /// Establish an outbound connection to [toAtSign]
  /// Returns OutboundClient, if connection is successful.
  /// Throws [ConnectionInvalidException] for any exceptions
  Future<OutboundClient> _connect(String? toAtSign) async {
    var outBoundClient = NotifyConnectionsPool.getInstance().get(toAtSign);
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
    } on Exception catch (e) {
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

  /// Prepares the notification key.
  /// Accepts [AtNotification]
  /// Returns the key of notification key.
  @visibleForTesting
  String prepareNotifyCommandBody(AtNotification atNotification) {
    String commandBody;
    commandBody = '${atNotification.notification}';
    var atMetaData = atNotification.atMetadata;
    if (atMetaData != null) {
      if (atNotification.atMetadata!.pubKeyCS != null) {
        commandBody =
            '$SHARED_WITH_PUBLIC_KEY_CHECK_SUM:${atNotification.atMetadata!.pubKeyCS}:$commandBody';
      }
      if (atNotification.atMetadata!.sharedKeyEnc != null) {
        commandBody =
            '$SHARED_KEY_ENCRYPTED:${atNotification.atMetadata!.sharedKeyEnc}:$commandBody';
      }
      if (atMetaData.ttr != null) {
        commandBody =
            'ttr:${atMetaData.ttr}:ccd:${atMetaData.isCascade}:$commandBody:${atNotification.atValue}';
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
    // appending id to the notify command.
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
