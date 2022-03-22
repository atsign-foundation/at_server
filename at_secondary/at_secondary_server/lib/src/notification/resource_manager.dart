import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/notification/notification_request.dart';
import 'package:at_secondary/src/notification/notification_request_manager.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/feature_cache.dart';
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
  Future<void> _sendNotifications(
      OutboundClient outBoundClient, Iterator iterator) async {
    String? notifyResponse;
    var atNotification;
    var errorList = [];
    // Setting NotificationRequest to default feature - NotifyWithoutId
    NotificationRequest notificationRequest =
        NotificationRequestManager.getInstance()
            .getNotificationRequestByFeature();
    // Verify if receiver atSign has 'NotifyWithId' enabled.
    if (await _isFeatureEnabled(outBoundClient, notifyWithId)) {
      notificationRequest = NotificationRequestManager.getInstance()
          .getNotificationRequestByFeature(feature: notifyWithId);
    }
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

  ///Adds the error notifications back to queue.
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

  /// Verifies if [feature] is enabled on the receiver's atSign.
  /// If enabled, returns true else false.
  ///
  /// Initially check's in the [FeatureCache] i
  Future<bool> _isFeatureEnabled(
      OutboundClient outBoundClient, String featureName) async {
    // Check if feature is present in cache.
    try {
      var featureCacheEntry = FeatureCache.getInstance()
          .getFeatureCacheEntry(outBoundClient.toAtSign!, featureName);
      // If the lastUpdatedEpoch is less than 15 minutes, return [feature.isEnabled] from the cache.
      if (DateTime.now()
              .toUtc()
              .difference(DateTime.fromMillisecondsSinceEpoch(
                  featureCacheEntry.lastUpdatedEpoch))
              .inMinutes <
          15) {
        return featureCacheEntry.feature.isEnabled;
      }
    } on KeyNotFoundException {
      logger.finer(
          '$featureName does not exist in feature cache. Fetching from ${outBoundClient.toAtSign} cloud secondary');
    }
    // Fetch the info from toAtSign cloud secondary
    var infoFeaturesMap = await _getInfoResponse(outBoundClient);
    // Update the feature cache
    _updateFeatureCache(outBoundClient.toAtSign!, infoFeaturesMap);
    // Returns true if feature is enabled, else false.
    return infoFeaturesMap.containsKey(featureName);
  }

  /// Returns the [Info] of [OutboundClient.toAtSign]
  Future<Map<String, dynamic>> _getInfoResponse(
      OutboundClient outBoundClient) async {
    String? infoResponse;
    try {
      infoResponse = await outBoundClient.info();
      if (infoResponse == null || infoResponse.startsWith('error:')) {
        return {};
      }
    } on Exception {
      logger.finer(
          'Exception occurred on getting the info of ${outBoundClient.toAtSign}');
    }
    return (jsonDecode(infoResponse!.replaceAll('data:', '')))['features'];
  }

  /// Updates the [Info] response into [FeatureCache]
  void _updateFeatureCache(String atSign, Map<String, dynamic> infoMap) {
    Map<String, FeatureCacheEntry> featureCacheMap = {};
    infoMap.forEach((key, value) {
      var featureCacheEntry = FeatureCacheEntry()
        ..feature = (Feature()
          ..featureName = key
          ..status = value['status']
          ..description = value['description'])
        ..lastUpdatedEpoch = (DateTime.now().toUtc().millisecondsSinceEpoch);
      featureCacheMap.putIfAbsent(key, () => featureCacheEntry);
    });
    // setFeatures clears the cache and updates all entries.
    // Hence do not use inside the forEach loop.
    FeatureCache.getInstance().setFeatures(atSign, featureCacheMap);
  }
}
