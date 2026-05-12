import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/regex_util.dart' as sync_filter;
import 'package:at_secondary/src/verb/metrics/metrics_provider.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_logger.dart';

final _logger = AtSignLogger('MetricsImpl');

class InboundMetricImpl extends MetricProvider {
  InboundMetricImpl(super.atServer);

  @override
  String getMetrics({String? regex}) {
    return atServer.inboundConnectionManager.pool
        .getActiveConnectionSize()
        .toString();
  }

  @override
  String getName() {
    return 'activeInboundConnections';
  }
}

class InboundSummaryMetricImpl extends MetricProvider {
  InboundSummaryMetricImpl(super.atServer);

  @override
  Map<String, dynamic> getMetrics({String? regex}) {
    return atServer.inboundConnectionManager.pool.getStats(detailed: false);
  }

  @override
  String getName() {
    return 'activeInboundConnectionsSummary';
  }
}

class InboundDetailedMetricImpl extends MetricProvider {
  InboundDetailedMetricImpl(super.atServer);

  @override
  Map<String, dynamic> getMetrics({String? regex}) {
    return atServer.inboundConnectionManager.pool.getStats(detailed: true);
  }

  @override
  String getName() {
    return 'activeInboundConnectionsDetailed';
  }
}

class OutBoundMetricImpl extends MetricProvider {
  OutBoundMetricImpl(super.atServer);

  @override
  String getMetrics({String? regex}) {
    return atServer.outboundClientManager.getActiveConnectionSize().toString();
  }

  @override
  String getName() {
    return 'activeOutboundConnections';
  }
}

class LastCommitIDMetricImpl extends MetricProvider {
  LastCommitIDMetricImpl(super.atServer);

  @override
  Future<String> getMetrics(
      {String? regex, List<String>? enrolledNamespaces}) async {
    _logger.finer('In commitID getMetrics...regex : $regex');
    if (regex == null && enrolledNamespaces == null) {
      return atServer.commitLog.lastCommittedSequenceNumber().toString();
    }
    final effectiveRegex = regex ?? '.*';
    int? lastCommitID;
    await for (final entry in atServer.commitLog.iterate(
        where: (e) => sync_filter.shouldIncludeKeyInSyncResponse(
            e.atKey!, effectiveRegex,
            enrolledNamespace: enrolledNamespaces))) {
      if (entry.commitId != null &&
          (lastCommitID == null || entry.commitId! > lastCommitID)) {
        lastCommitID = entry.commitId;
      }
    }
    return lastCommitID.toString();
  }

  @override
  String getName() {
    return 'lastCommitID';
  }
}

class SecondaryStorageMetricImpl extends MetricProvider {
  SecondaryStorageMetricImpl(super.atServer);

  @override
  int getMetrics({String? regex}) {
    var secondaryStorageSize = 0;
    //The listSync function returns the list of files in the hive storage location.
    // The below loop iterates recursively into sub-directories over each file and gets the file size using lengthSync function
    Directory(AtSecondaryConfig.storagePath)
        .listSync(recursive: true)
        .forEach((element) {
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

class MostVisitedAtSignMetricImpl extends MetricProvider {
  MostVisitedAtSignMetricImpl(super.atServer);

  @override
  Future<String> getMetrics({String? regex}) async {
    final length = AtSecondaryConfig.stats_top_visits!;
    final AtAccessLog atAccessLog = atServer.accessLog;
    return jsonEncode(await atAccessLog.mostVisitedAtSigns(length));
  }

  @override
  String getName() {
    return 'topAtSigns';
  }
}

class MostVisitedAtKeyMetricImpl extends MetricProvider {
  MostVisitedAtKeyMetricImpl(super.atServer);

  @override
  Future<String> getMetrics({String? regex}) async {
    final length = AtSecondaryConfig.stats_top_keys!;
    final AtAccessLog atAccessLog = atServer.accessLog;
    return jsonEncode(await atAccessLog.mostVisitedKeys(length));
  }

  @override
  String getName() {
    return 'topKeys';
  }
}

class SecondaryServerVersion extends MetricProvider {
  SecondaryServerVersion(super.atServer);

  @override
  String? getMetrics({String? regex}) {
    return AtSecondaryConfig.secondaryServerVersion;
  }

  @override
  String getName() {
    return 'secondaryServerVersion';
  }
}

class LastLoggedInDatetimeMetricImpl extends MetricProvider {
  LastLoggedInDatetimeMetricImpl(super.atServer);

  @override
  Future<String?> getMetrics({String? regex}) async {
    final AtAccessLog atAccessLog = atServer.accessLog;
    var entry = await atAccessLog.getLastAccessLogEntry();
    return entry.requestDateTime!.toUtc().toString();
  }

  @override
  String getName() {
    return 'LastLoggedInDatetime';
  }
}

class DiskSizeMetricImpl extends MetricProvider {
  DiskSizeMetricImpl(super.atServer);

  @override
  String getMetrics({String? regex}) {
    var diskSize = 0;
    //The listSync function returns the list of files in the hive storage location.
    // In the loop iterating recursively into sub-directories and gets the size of each file using lengthSync
    for (var file
        in Directory(AtSecondaryConfig.storagePath).listSync(recursive: true)) {
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

class LastPkamMetricImpl extends MetricProvider {
  LastPkamMetricImpl(super.atServer);

  @override
  Future<String?> getMetrics({String? regex}) async {
    final AtAccessLog atAccessLog = atServer.accessLog;
    var entry = await atAccessLog.getLastPkamAccessLogEntry();
    return (entry != null)
        ? entry.requestDateTime!.toUtc().toString()
        : 'Not Available';
  }

  @override
  String getName() {
    return 'LastPkam';
  }
}

class NotificationsMetricImpl extends MetricProvider {
  NotificationsMetricImpl(super.atServer);

  @override
  Future<String?> getMetrics({String? regex}) async {
    Map<String, dynamic> metricsMap = <String, dynamic>{
      "total": 0,
      "type": <String, int>{
        "sent": 0,
        "received": 0,
        "self": 0,
      },
      "status": <String, int>{
        "delivered": 0,
        "failed": 0,
        "errored": 0,
        "queued": 0,
        "expired": 0,
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
    metricsMap = await getNotificationStats(metricsMap);
    return jsonEncode(metricsMap);
  }

  Future<Map<String, dynamic>> getNotificationStats(
      Map<String, dynamic> metrics) async {
    int total = 0;
    for (final k in await atServer.notificationManager.getKeys()) {
      final n = await atServer.notificationManager.get(k);
      if (n == null) {
        continue;
      }
      total++;
      switch (n.type) {
        case null:
          break;
        case NotificationType.self:
        case NotificationType.received:
        case NotificationType.sent:
          metrics['type'][n.type!.name]++;
          break;
      }
      switch (n.notificationStatus) {
        case null:
          break;
        case NotificationStatus.queued:
        case NotificationStatus.delivered:
        case NotificationStatus.expired:
          metrics['status'][n.notificationStatus!.name]++;
          break;
        case NotificationStatus.errored:
          metrics['status'][n.notificationStatus!.name]++;
          metrics['status']['failed']++;
          break;
      }
      switch (n.opType) {
        case null:
          break;
        case OperationType.delete:
        case OperationType.update:
          metrics['operations'][n.opType!.name]++;
      }
      switch (n.messageType) {
        case null:
          break;
        case MessageType.key:
        case MessageType.text:
          metrics['messageType'][n.messageType!.name]++;
      }
    }
    metrics['total'] = total;
    metrics['createdOn'] = DateTime.now().millisecondsSinceEpoch;
    return metrics;
  }

  @override
  String getName() {
    return 'NotificationCount';
  }
}

class KeyStorageMetricImpl extends MetricProvider {
  KeyStorageMetricImpl(super.atServer);

  @override
  Future<String?> getMetrics({String? regex}) async {
    return atServer.currentAtSign;
  }

  @override
  String getName() {
    return 'atSign';
  }
}

class CommitLogCompactionStats extends MetricProvider {
  CommitLogCompactionStats(super.atServer);

  @override
  getMetrics({String? regex}) async {
    final keyValueStore = atServer.keyValueStore;
    if (keyValueStore.isKeyExists(AtConstants.commitLogCompactionKey)) {
      AtData? atData =
          await keyValueStore.get(AtConstants.commitLogCompactionKey);
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

class AccessLogCompactionStats extends MetricProvider {
  AccessLogCompactionStats(super.atServer);

  @override
  getMetrics({String? regex}) async {
    final keyValueStore = atServer.keyValueStore;
    if (keyValueStore.isKeyExists(AtConstants.accessLogCompactionKey)) {
      AtData? atData =
          await keyValueStore.get(AtConstants.accessLogCompactionKey);
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

class NotificationCompactionStats extends MetricProvider {
  NotificationCompactionStats(super.atServer);

  @override
  getMetrics({String? regex}) async {
    final keyValueStore = atServer.keyValueStore;
    if (keyValueStore.isKeyExists(AtConstants.notificationCompactionKey)) {
      AtData? atData =
          await keyValueStore.get(AtConstants.notificationCompactionKey);
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

class LatestCommitEntryOfEachKey extends MetricProvider {
  LatestCommitEntryOfEachKey(super.atServer);

  @override
  getMetrics({String? regex = '.*'}) async {
    final responseMap = <String, List<dynamic>>{};
    final atCommitLog = atServer.commitLog;
    // Phase 3.5a's box invariant guarantees one entry per atKey, so a
    // single walk yields the latest entry for every atKey.
    final hasRegex = regex != null && regex.isNotEmpty && regex != '.*';
    final pattern = hasRegex ? RegExp(regex) : null;
    await for (final commitEntry in atCommitLog.iterate(
        where: hasRegex
            ? (e) => e.atKey != null && pattern!.hasMatch(e.atKey!)
            : null)) {
      responseMap[commitEntry.atKey!] = [
        commitEntry.commitId,
        commitEntry.operation!.name
      ];
    }
    return jsonEncode(responseMap);
  }

  @override
  String getName() {
    return 'LatestCommitEntryOfEachKey';
  }
}
