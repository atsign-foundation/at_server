import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_logger.dart';

/// Class that is responsible for sending the notifications.
class ResourceManager {
  static final ResourceManager _singleton = ResourceManager._internal();
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  ResourceManager._internal();

  factory ResourceManager.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('NotificationResourceManager');
  var quarantineDuration = AtSecondaryConfig.notificationQuarantineDuration;
  var notificationJobFrequency = AtSecondaryConfig.notificationJobFrequency;

  ///Runs for every configured number of seconds(5).
  void schedule() async {
    _isRunning = true;
    String? atSign;
    late Iterator notificationIterator;
    try {
      //1. Check how many outbound connections are free.
      var N = NotifyConnectionsPool.getInstance().getCapacity();

      //2. Get the atsign on priority basis.
      var atsignIterator = AtNotificationMap.getInstance().getAtSignToNotify(N);

      while (atsignIterator.moveNext()) {
        atSign = atsignIterator.current;
        notificationIterator = QueueManager.getInstance().dequeue(atSign);
        //3. Connect to the atSign
        var outboundClient = await _connect(atSign);
        if (outboundClient != null) {
          // If outbound connection is established, remove the atSign from the _waitTimeMap
          // to avoid getting same atSign.
          AtNotificationMap.getInstance().removeWaitTimeEntry(atSign);
          _sendNotifications(outboundClient, notificationIterator);
        }
      }
    } on ConnectionInvalidException catch (e) {
      var errorList = [];
      logger.severe('Connection failed for $atSign : ${e.toString()}');
      AtNotificationMap.getInstance().quarantineMap[atSign] =
          DateTime.now().add(Duration(seconds: quarantineDuration!));
      while (notificationIterator.moveNext()) {
        errorList.add(notificationIterator.current);
      }
      _enqueueErrorList(errorList);
    } finally {
      //4. sleep for 5 seconds to refrain blocking main thread and call schedule again.
      return Future.delayed(Duration(seconds: notificationJobFrequency!))
          .then((value) => schedule());
    }
  }

  /// Establish an outbound connection to [toAtSign]
  /// Returns OutboundClient, if connection is successful.
  /// Throws [ConnectionInvalidException] for any exceptions
  Future<OutboundClient?> _connect(String? toAtSign) async {
    var outBoundClient = NotifyConnectionsPool.getInstance().get(toAtSign);
    try {
      if (!outBoundClient.isHandShakeDone) {
        var isConnected = await outBoundClient.connect();
        logger.finer('connect result: $isConnected');
        if (isConnected) {
          return outBoundClient;
        }
      }
    } on Exception catch (e) {
      outBoundClient.inboundConnection.getMetaData().isClosed = true;
      logger.finer('connect result: $e');
      throw ConnectionInvalidException('Connection failed');
    }
    return null;
  }

  /// Send the Notification to [atNotificationList.toAtSign]
  void _sendNotifications(
      OutboundClient outBoundClient, Iterator iterator) async {
    var notifyResponse;
    var atNotification;
    var errorList = [];
    // For list of notifications, iterate on each notification and process the notification.
    try {
      while (iterator.moveNext()) {
        atNotification = iterator.current;
        var key = _prepareNotificationKey(atNotification);
        notifyResponse = await outBoundClient.notify(key);
        logger.info('notifyResult : $notifyResponse');
        await _notifyResponseProcessor(
            notifyResponse, atNotification, errorList);
      }
    } on Exception catch (e) {
      logger.severe(
          'Exception in processing the notification ${atNotification.id} : ${e.toString()}');
      errorList.add(atNotification);
    } finally {
      //1. Adds errored notifications back to queue.
      _enqueueErrorList(errorList);
      //2. Calling close method to close the outbound connection
      outBoundClient.outboundConnection?.close();
    }
  }

  /// If the notification response is success, marks the status as [NotificationStatus.delivered]
  /// Else, marks the notification status as [NotificationStatus.queued] and reduce the priority and add back to queue.
  Future<void> _notifyResponseProcessor(
      String? response, AtNotification? atNotification, List errorList) async {
    if (response == 'data:success') {
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      var notifyEle = await (notificationKeyStore.get(atNotification!.id));
      atNotification.notificationStatus = NotificationStatus.delivered;
      await AtNotificationKeystore.getInstance().put(notifyEle?.id, notifyEle);
      var metadata = Metadata()
        ..sharedKeyStatus =
            getSharedKeyName(SharedKeyStatus.SHARED_WITH_NOTIFIED);
      await SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(
              AtSecondaryServerImpl.getInstance().currentAtSign)!
          .getSecondaryKeyStore()!
          .putMeta(atNotification.notification!, AtMetadataAdapter(metadata));
    } else {
      errorList.add(atNotification);
    }
  }

  /// Prepares the notification key.
  /// Accepts [AtNotification]
  /// Returns the key of notification key.
  String _prepareNotificationKey(AtNotification atNotification) {
    var key;
    key = '${atNotification.notification}';
    var atMetaData = atNotification.atMetadata;
    if (atMetaData != null) {
      if (atMetaData.ttr != null) {
        key =
            'ttr:${atMetaData.ttr}:ccd:${atMetaData.isCascade}:$key:${atNotification.atValue}';
      }
      if (atMetaData.ttb != null) {
        key = 'ttb:${atMetaData.ttb}:$key';
      }
      if (atMetaData.ttl != null) {
        key = 'ttl:${atMetaData.ttl}:$key';
      }
    }
    key = 'notifier:${atNotification.notifier}:$key';
    key =
        'messageType:${atNotification.messageType.toString().split('.').last}:$key';
    if (atNotification.opType != null) {
      key = '${atNotification.opType.toString().split('.').last}:$key';
    }
    return key;
  }

  ///Adds the errored notifications back to queue.
  void _enqueueErrorList(List errorList) {
    if (errorList.isEmpty) {
      return;
    }
    var iterator = errorList.iterator;
    var maxRetries = AtSecondaryConfig.maxNotificationRetries;
    while (iterator.moveNext()) {
      var atNotification = iterator.current;
      // If number retries are equal to maximum number of notifications, notifications are not further processed
      // hence remove entries from waitTimeMap and quarantineMap
      if (atNotification.retryCount == maxRetries) {
        AtNotificationMap.getInstance()
            .removeWaitTimeEntry(atNotification.toAtSign);
        AtNotificationMap.getInstance()
            .removeQuarantineEntry(atNotification.toAtSign);
        continue;
      }
      atNotification.notificationStatus = NotificationStatus.errored;
      QueueManager.getInstance().enqueue(atNotification);
    }
  }
}
