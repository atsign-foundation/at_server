import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';

/// Class that is responsible for sending the notifications.
class ResourceManager {
  static final ResourceManager _singleton = ResourceManager._internal();

  ResourceManager._internal();

  factory ResourceManager.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('NotificationResourceManager');
  var quarantineDuration = AtSecondaryConfig.notificationQuarantineDuration;
  var notificationJobFrequency = AtSecondaryConfig.notificationJobFrequency;

  ///Runs for every configured number of seconds(5).
  void schedule() async {
    //1. Check how many outbound connections are free.
    var N = NotifyConnectionsPool.getInstance().getCapacity();

    //2. Get the atsign on priority basis.
    var atsignIterator = AtNotificationMap.getInstance().getAtSignToNotify(N);

    while (atsignIterator.moveNext()) {
      var atsign = atsignIterator.current;
      //3. Connect to the atsign
      var outboundClient = await _connect(atsign);
      // If connection fails, quarantine the atsign for 10 seconds.
      if (outboundClient == null) {
        AtNotificationMap.getInstance().quarantineMap.putIfAbsent(atsign,
            () => DateTime.now().add(Duration(seconds: quarantineDuration)));
      }
      // If outbound connection is established, remove the atsign from the _waitTimeMap
      // to avoid getting same atsign.
      if (outboundClient != null) {
        AtNotificationMap.getInstance().removeEntry(atsign);
        var notificationIterator = QueueManager.getInstance().dequeue(atsign);
        _sendNotifications(outboundClient, notificationIterator);
      }
    }
    //4. sleep for 5 seconds to refrain blocking main thread and call schedule again.
    return Future.delayed(Duration(seconds: notificationJobFrequency))
        .then((value) => schedule());
  }

  /// Establish an outbound connection to [toAtSign]
  /// Returns OutboundClient, if connection is successful.
  /// Else, returns null.
  Future<OutboundClient> _connect(String toAtSign) async {
    var outBoundClient = NotifyConnectionsPool.getInstance().get(toAtSign);
    try {
      if (!outBoundClient.isHandShakeDone) {
        var isConnected = await outBoundClient.connect();
        logger.finer('connect result: ${isConnected}');
        if (isConnected) {
          return outBoundClient;
        }
      }
    } on Exception catch (e) {
      logger.finer('connect result: ${e}');
    }
    return null;
  }

  /// Send the Notification to [atNotificationList.toAtSign]
  void _sendNotifications(
      OutboundClient outBoundClient, Iterator iterator) async {
    var errorList = [];
    var notifyResponse;
    var atNotification;
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
    } finally {
      //1. Add the errored notifications back to queue.
      errorList.forEach((atNotification) {
        QueueManager.getInstance().enqueue(atNotification);
      });

      //2. Setting isStale on  outbound connection metadata to true to remove the connection from
      //   Notification Connection Pool.
      outBoundClient.outboundConnection.metaData.isStale = true;
    }
  }

  /// If the notification response is success, marks the status as [NotificationStatus.delivered]
  /// Else, marks the notification status as [NotificationStatus.queued] and reduce the priority and add back to queue.
  void _notifyResponseProcessor(
      String response, AtNotification atNotification, List errorList) async {
    if (response == 'data:success') {
      var notificationKeyStore = await AtNotificationKeystore.getInstance();
      var notifyEle = await notificationKeyStore.get(atNotification.id);
      atNotification.notificationStatus = NotificationStatus.delivered;
      await AtNotificationKeystore.getInstance().put(notifyEle.id, notifyEle);
    } else {
      atNotification.notificationStatus = NotificationStatus.errored;
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
            'ttr:${atMetaData.ttr}:ccd:${atMetaData.isCascade}:${key}:${atNotification.atValue}';
      }
      if (atMetaData.ttb != null) {
        key = 'ttb:${atMetaData.ttb}:${key}';
      }
      if (atMetaData.ttl != null) {
        key = 'ttl:${atMetaData.ttl}:${key}';
      }
    }
    key = 'notifier:${atNotification.notifier}:${key}';
    key =
        'messageType:${atNotification.messageType.toString().split('.').last}:${key}';
    if (atNotification.opType != null) {
      key = '${atNotification.opType.toString().split('.').last}:${key}';
    }
    return key;
  }
}
