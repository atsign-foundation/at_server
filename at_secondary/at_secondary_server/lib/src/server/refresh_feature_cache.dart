import 'dart:convert';
import 'dart:isolate';

import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/feature_cache.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';

/// Class responsible for refreshing the feature cache
class RefreshFeatureCache {
  static final RefreshFeatureCache _singleton = RefreshFeatureCache._internal();

  RefreshFeatureCache._internal();

  factory RefreshFeatureCache.getInstance() {
    return _singleton;
  }

  SendPort? _childIsolateSendPort;

  static final logger = AtSignLogger('UpdateFeatureCache');

  /// Spawns an isolate job to update the FeatureCache
  Future<void> refreshInfoCache() async {
    var mainIsolateReceivePort = ReceivePort();
    FeatureCache.getInstance().cacheObservers.add(this);
    await Isolate.spawn(
        _infoCacheIsolate, [mainIsolateReceivePort.sendPort]);
    mainIsolateReceivePort.listen((data) async {
      if (_childIsolateSendPort == null && data is SendPort) {
        _childIsolateSendPort = data;
      }
      if (data is Map && data.isNotEmpty) {
        data.forEach((key, value) {
          FeatureCache.getInstance().setFeatures(key, value);
        });
      }
    });
  }

  /// Sends the atSign to the child isolate - _infoCacheIsolate
  void notifyAtSign(String atSign) {
    _childIsolateSendPort?.send(atSign);
  }

  /// Isolate job to verify certificates expiry. Sends [true] to main isolate upon creation of [restart] file which acts as a trigger
  /// to indicate the new certificates are in place.
  void _infoCacheIsolate(List<SendPort> commList) async {
    var childIsolateReceivePort = ReceivePort();
    var mainIsolateSendPort = commList[0];
    mainIsolateSendPort.send(childIsolateReceivePort.sendPort);
    var atSignList = <String>[];

    // Listens to the data sent by main isolate
    childIsolateReceivePort.listen((data) {
      if (data is String) {
        atSignList.add(data);
      }
    });
    // Cron Job for updating the cache
    Cron().schedule(Schedule.parse('* * * * *'), () async {
      if (atSignList.isNotEmpty) {
        Future.forEach(atSignList,
            (String element) => _sendInfo(element, mainIsolateSendPort));
      }
    });
  }

  /// Send features from [Info] verb to the main isolate
  Future<void> _sendInfo(String toAtSign, SendPort sendPort) async {
    var featureMap = await _getInfo(toAtSign);
    if (featureMap.isEmpty) {
      return;
    }
    Map<String, FeatureCacheEntry> featureCacheMap = {};
    featureMap.forEach((key, value) {
      var featureCacheEntry = FeatureCacheEntry()
        ..feature = (Feature()
          ..featureName = key
          ..status = value['status']
          ..description = value['description'])
        ..lastUpdatedEpoch = (DateTime.now().toUtc().millisecondsSinceEpoch);
      featureCacheMap.putIfAbsent(key, () => featureCacheEntry);
    });
    sendPort.send({toAtSign: featureCacheMap});
  }

  /// Runs [Info] on the [toAtSign] and gets the details
  Future<Map> _getInfo(String toAtSign) async {
    Map featureMap = {};
    try {
      var outboundConnection = OutboundClientManager.getInstance()
          .getClient(toAtSign, DummyInboundConnection.getInstance());
      // Setting handshake to false because info verb runs on unauthenticated connection
      await outboundConnection?.connect(handshake: false);
      var infoResponse = await outboundConnection?.info();
      outboundConnection?.close();
      featureMap =
          (jsonDecode(infoResponse!.replaceAll('data:', '')))['features'];
    } on Exception {
      logger.finer('Exception occurred while getting the info for $toAtSign');
    }
    return featureMap;
  }
}
