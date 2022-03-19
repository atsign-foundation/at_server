import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/notification_request_manager.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
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
      await _enqueueErrorList(errorList);
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
    String version = await _getVersion(outBoundClient);
    var notificationRequest = NotificationRequestManager.getInstance()
        .getNotificationRequest(version);
    try {
      // For list of notifications, iterate on each notification and process the notification.
      while (iterator.moveNext()) {
        atNotification = iterator.current;
        var notification = notificationRequest.getRequest(atNotification);
        notifyResponse = await outBoundClient.notify(notification.request);
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
      await _enqueueErrorList(errorList);

      //2. Setting isStale on  outbound connection metadata to true to remove the connection from
      //   Notification Connection Pool.
      await outBoundClient.outboundConnection!.close();
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

  ///Adds the errored notifications back to queue.
  Future<void> _enqueueErrorList(List errorList) async {
    if (errorList.isEmpty) {
      return;
    }
    var iterator = errorList.iterator;
    var maxRetries = AtSecondaryConfig.maxNotificationRetries;
    while (iterator.moveNext()) {
      var atNotification = iterator.current;
      // Update the status to errored and persist the notification to keystore.
      atNotification?.notificationStatus = NotificationStatus.errored;
      await AtNotificationKeystore.getInstance()
          .put(atNotification?.id, atNotification);
      // If number retries are equal to maximum number of notifications, notifications are not further processed
      // hence remove entries from waitTimeMap and quarantineMap
      if (atNotification.retryCount == maxRetries) {
        AtNotificationMap.getInstance()
            .removeWaitTimeEntry(atNotification.toAtSign);
        AtNotificationMap.getInstance()
            .removeQuarantineEntry(atNotification.toAtSign);
        logger.info(
            'Failed to notify ${atNotification.id}. Maximum retries reached');
        continue;
      }
      logger.info(
          'Retrying to notify: ${atNotification.id} retry count: ${atNotification.retryCount}');
      QueueManager.getInstance().enqueue(atNotification);
    }
  }

  /// Return's version of the receiver's secondary server
  /// If failed, returns the default version.
  Future<String> _getVersion(OutboundClient outBoundClient) async {
    //
    var defaultVersion = '3.0.12';
    String? infoResponse;
    try {
      infoResponse = await outBoundClient.info();
      // If infoResponse is null, fallback to default version
      if (infoResponse == null || infoResponse.startsWith('error:')) {
        logger.finer(
            'Failed to fetch version, falling back to default version: $defaultVersion');
        return defaultVersion;
      }
    } on Exception {
      logger.finer(
          'Exception occurred in fetching the version, falling back to default version: $defaultVersion');
      return defaultVersion;
    }
    var infoMap = jsonDecode(infoResponse.replaceAll('data:', ''));
    // If version is null, return the default version.
    return infoMap['version'] ??= defaultVersion;
  }
}
