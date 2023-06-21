import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/connection_metrics.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/regex_util.dart';
import 'package:at_secondary/src/verb/metrics/metrics_provider.dart';
import 'package:at_commons/at_commons.dart';

class InboundMetricImpl implements MetricProvider {
  static final InboundMetricImpl _singleton = InboundMetricImpl._internal();
  var connectionMetrics = ConnectionMetricsImpl();

  InboundMetricImpl._internal();

  factory InboundMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  String getMetrics({String? regex}) {
    var connections = connectionMetrics.getInboundConnections().toString();
    return connections;
  }

  @override
  String getName() {
    return 'activeInboundConnections';
  }
}

class OutBoundMetricImpl implements MetricProvider {
  static final OutBoundMetricImpl _singleton = OutBoundMetricImpl._internal();
  var connectionMetrics = ConnectionMetricsImpl();

  OutBoundMetricImpl._internal();

  factory OutBoundMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  String getMetrics({String? regex}) {
    var connections = connectionMetrics.getOutboundConnections().toString();
    return connections;
  }

  @override
  String getName() {
    return 'activeOutboundConnections';
  }
}

class LastCommitIDMetricImpl implements MetricProvider {
  static final LastCommitIDMetricImpl _singleton =
      LastCommitIDMetricImpl._internal();
  var _atCommitLog;

  set atCommitLog(value) {
    _atCommitLog = value;
  }

  LastCommitIDMetricImpl._internal();

  factory LastCommitIDMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<String> getMetrics({String? regex}) async {
    logger.finer('In commitID getMetrics...regex : $regex');
    var lastCommitID;
    if (regex != null) {
      lastCommitID =
          await _atCommitLog.lastCommittedSequenceNumberWithRegex(regex);
      return lastCommitID.toString();
    }
    lastCommitID = _atCommitLog.lastCommittedSequenceNumber().toString();
    return lastCommitID;
  }

  @override
  String getName() {
    return 'lastCommitID';
  }
}

class SecondaryStorageMetricImpl implements MetricProvider {
  static final SecondaryStorageMetricImpl _singleton =
      SecondaryStorageMetricImpl._internal();
  var secondaryStorageLocation = Directory(AtSecondaryServerImpl.storagePath!);

  SecondaryStorageMetricImpl._internal();

  factory SecondaryStorageMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  int getMetrics({String? regex}) {
    var secondaryStorageSize = 0;
    //The listSync function returns the list of files in the hive storage location.
    // The below loop iterates recursively into sub-directories over each file and gets the file size using lengthSync function
    secondaryStorageLocation.listSync(recursive: true).forEach((element) {
      if (element is File) {
        secondaryStorageSize =
            secondaryStorageSize + File(element.path).lengthSync();
      }
    });
    //Return bytes
    return secondaryStorageSize;
  }

  @override
  String getName() {
    return 'secondaryStorageSize';
  }
}

class MostVisitedAtSignMetricImpl implements MetricProvider {
  static final MostVisitedAtSignMetricImpl _singleton =
      MostVisitedAtSignMetricImpl._internal();

  MostVisitedAtSignMetricImpl._internal();

  factory MostVisitedAtSignMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<String> getMetrics({String? regex}) async {
    final length = AtSecondaryConfig.stats_top_visits!;
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    return jsonEncode(await atAccessLog?.mostVisitedAtSigns(length));
  }

  @override
  String getName() {
    return 'topAtSigns';
  }
}

class MostVisitedAtKeyMetricImpl implements MetricProvider {
  static final MostVisitedAtKeyMetricImpl _singleton =
      MostVisitedAtKeyMetricImpl._internal();

  MostVisitedAtKeyMetricImpl._internal();

  factory MostVisitedAtKeyMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<String> getMetrics({String? regex}) async {
    final length = AtSecondaryConfig.stats_top_keys!;
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    return jsonEncode(await atAccessLog?.mostVisitedKeys(length));
  }

  @override
  String getName() {
    return 'topKeys';
  }
}

class SecondaryServerVersion implements MetricProvider {
  static final SecondaryServerVersion _singleton =
      SecondaryServerVersion._internal();

  SecondaryServerVersion._internal();

  factory SecondaryServerVersion.getInstance() {
    return _singleton;
  }

  @override
  String? getMetrics({String? regex}) {
    return AtSecondaryConfig.secondaryServerVersion;
  }

  @override
  String getName() {
    return 'secondaryServerVersion';
  }
}

class LastLoggedInDatetimeMetricImpl implements MetricProvider {
  static final LastLoggedInDatetimeMetricImpl _singleton =
      LastLoggedInDatetimeMetricImpl._internal();

  LastLoggedInDatetimeMetricImpl._internal();

  factory LastLoggedInDatetimeMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<String?> getMetrics({String? regex}) async {
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    var entry = await atAccessLog!.getLastAccessLogEntry();
    return entry.requestDateTime!.toUtc().toString();
  }

  @override
  String getName() {
    return 'LastLoggedInDatetime';
  }
}

class DiskSizeMetricImpl implements MetricProvider {
  static final DiskSizeMetricImpl _singleton = DiskSizeMetricImpl._internal();

  DiskSizeMetricImpl._internal();

  factory DiskSizeMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  String getMetrics({String? regex}) {
    Directory storageLocation = Directory(AtSecondaryServerImpl.storagePath!);
    var diskSize = 0;
    //The listSync function returns the list of files in the hive storage location.
    // In the loop iterating recursively into sub-directories and gets the size of each file using lengthSync
    for (var file in storageLocation.listSync(recursive: true)) {
      if (file is File) {
        diskSize = diskSize + File(file.path).lengthSync();
      }
    }
    //Return total size
    return formatBytes(diskSize, 2);
  }

  @override
  String getName() {
    return 'diskSize';
  }

  String formatBytes(int bytes, int decimals) {
    Map<String, String> storageData = <String, String>{};
    if (bytes <= 0) {
      storageData['size'] = '0';
      storageData['unit'] = 'B';
      return jsonEncode(storageData);
    }
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];
    var i = (log(bytes) / log(1024)).floor();
    storageData['size'] = ((bytes / pow(1024, i)).toStringAsFixed(decimals));
    storageData['units'] = suffixes[i];
    return jsonEncode(storageData);
  }
}

class LastPkamMetricImpl implements MetricProvider {
  static final LastPkamMetricImpl _singleton = LastPkamMetricImpl._internal();

  LastPkamMetricImpl._internal();

  factory LastPkamMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<String?> getMetrics({String? regex}) async {
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    var entry = await atAccessLog!.getLastPkamAccessLogEntry();
    return (entry != null)
        ? entry.requestDateTime!.toUtc().toString()
        : 'Not Available';
  }

  @override
  String getName() {
    return 'LastPkam';
  }
}

class NotificationsMetricImpl implements MetricProvider {
  static final NotificationsMetricImpl _singleton =
      NotificationsMetricImpl._internal();

  NotificationsMetricImpl._internal();

  factory NotificationsMetricImpl.getInstance() {
    return _singleton;
  }

  String _asString(dynamic enumData) {
    return enumData == null ? 'null' : enumData.toString().split('.')[1];
  }

  @override
  Future<String?> getMetrics({String? regex}) async {
    Map<String, dynamic> _metricsMap = <String, dynamic>{
      "total": 0,
      "type": <String, int>{
        "sent": 0,
        "received": 0,
      },
      "status": <String, int>{
        "delivered": 0,
        "failed": 0,
        "queued": 0,
      },
      "operations": <String, int>{
        "update": 0,
        "delete": 0,
      },
      "messageType": <String, int>{
        "key": 0,
        "text": 0,
      },
      "createdOn": 0,
    };
    _metricsMap = await getNotificationStats(_metricsMap);
    return jsonEncode(_metricsMap);
  }

  bool _check(var notifications, String key, String? value) {
    return _asString(notifications.toJson()[key]) == value;
  }

  Future<Map<String, dynamic>> getNotificationStats(
      Map<String, dynamic> _metrics) async {
    AtNotificationKeystore notificationKeystore =
        AtNotificationKeystore.getInstance();
    List notificationsList = await notificationKeystore.getValues();
    _metrics['total'] = notificationsList.length;
    for (var notifications in notificationsList) {
      if (_check(notifications, 'type', 'sent')) {
        _metrics['type']['sent']++;
      } else if (_check(notifications, 'type', 'received')) {
        _metrics['type']['received']++;
      }
      if (_check(notifications, 'notificationStatus', 'delivered')) {
        _metrics['status']['delivered']++;
      } else if (_check(notifications, 'notificationStatus', 'errored')) {
        _metrics['status']['failed']++;
      } else if (_check(notifications, 'notificationStatus', 'queued') ||
          _check(notifications, 'status', null)) {
        _metrics['status']['queued']++;
      }
      if (_check(notifications, 'opType', 'update')) {
        _metrics['operations']['update']++;
      } else if (_check(notifications, 'opType', 'delete')) {
        _metrics['operations']['delete']++;
      }
      if (_check(notifications, 'messageType', 'key')) {
        _metrics['messageType']['key']++;
      } else if (_check(notifications, 'messageType', 'text')) {
        _metrics['messageType']['text']++;
      }
    }
    _metrics['createdOn'] = DateTime.now().millisecondsSinceEpoch;
    return _metrics;
  }

  @override
  String getName() {
    return 'NotificationCount';
  }
}

class KeyStorageMetricImpl implements MetricProvider {
  static final KeyStorageMetricImpl _singleton =
      KeyStorageMetricImpl._internal();

  KeyStorageMetricImpl._internal();

  factory KeyStorageMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<String?> getMetrics({String? regex}) async {
    return AtSecondaryServerImpl.getInstance().currentAtSign;
  }

  @override
  String getName() {
    return 'atSign';
  }
}

class CommitLogCompactionStats implements MetricProvider {
  static final CommitLogCompactionStats _singleton =
      CommitLogCompactionStats.internal();

  CommitLogCompactionStats.internal();

  factory CommitLogCompactionStats.getInstance() {
    return _singleton;
  }

  @override
  getMetrics({String? regex}) async {
    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(
            AtSecondaryServerImpl.getInstance().currentAtSign)
        ?.getSecondaryKeyStore();
    if (keyStore!.isKeyExists(commitLogCompactionKey)) {
      AtData? atData = await keyStore.get(commitLogCompactionKey);
      if (atData != null && atData.data != null) {
        return atData.data;
      }
    }
    return jsonEncode({});
  }

  @override
  String getName() {
    return 'CommitLogCompactionStats';
  }
}

class AccessLogCompactionStats implements MetricProvider {
  static final AccessLogCompactionStats _singleton =
      AccessLogCompactionStats._internal();

  AccessLogCompactionStats._internal();

  factory AccessLogCompactionStats.getInstance() {
    return _singleton;
  }

  @override
  getMetrics({String? regex}) async {
    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(
            AtSecondaryServerImpl.getInstance().currentAtSign)
        ?.getSecondaryKeyStore();
    if (keyStore!.isKeyExists(accessLogCompactionKey)) {
      AtData? atData = await keyStore.get(accessLogCompactionKey);
      if (atData != null && atData.data != null) {
        return atData.data;
      }
    }
    return jsonEncode({});
  }

  @override
  String getName() {
    return 'AccessLogCompactionStats';
  }
}

class NotificationCompactionStats implements MetricProvider {
  static final NotificationCompactionStats _singleton =
      NotificationCompactionStats.internal();

  NotificationCompactionStats.internal();

  factory NotificationCompactionStats.getInstance() {
    return _singleton;
  }

  @override
  getMetrics({String? regex}) async {
    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(
            AtSecondaryServerImpl.getInstance().currentAtSign)
        ?.getSecondaryKeyStore();
    if (keyStore!.isKeyExists(notificationCompactionKey)) {
      AtData? atData = await keyStore.get(notificationCompactionKey);
      if (atData != null && atData.data != null) {
        return atData.data;
      }
    }
    return jsonEncode({});
  }

  @override
  String getName() {
    return 'NotificationCompactionStats';
  }
}

class LatestCommitEntryOfEachKey implements MetricProvider {
  @override
  getMetrics({String? regex = '.*'}) async {
    var responseMap = <String, List<dynamic>>{};
    var atCommitLog = await (AtCommitLogManagerImpl.getInstance()
        .getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign));

    Iterator commitEntryIterator = atCommitLog!.getEntries(-1, regex: regex);

    while (commitEntryIterator.moveNext()) {
      CommitEntry commitEntry = commitEntryIterator.current.value;
      responseMap[commitEntry.atKey!] = [
        commitEntry.commitId,
        commitEntry.operation.name
      ];
    }
    return jsonEncode(responseMap);
  }

  @override
  String getName() {
    return 'LatestCommitEntryOfEachKey';
  }
}
