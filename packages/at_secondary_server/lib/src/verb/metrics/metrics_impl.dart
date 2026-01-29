import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/regex_util.dart';
import 'package:at_secondary/src/verb/metrics/metrics_provider.dart';
import 'package:at_commons/at_commons.dart';

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
    logger.finer('In commitID getMetrics...regex : $regex');
    int? lastCommitID;
    if (regex != null || enrolledNamespaces != null) {
      regex ??= '.*';
      lastCommitID = await atServer.commitLog
          .lastCommittedSequenceNumberWithRegex(regex,
              enrolledNamespace: enrolledNamespaces);
      return lastCommitID.toString();
    }
    lastCommitID = atServer.commitLog.lastCommittedSequenceNumber();
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
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(atServer.currentAtSign));
    return jsonEncode(await atAccessLog?.mostVisitedAtSigns(length));
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
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(atServer.currentAtSign));
    return jsonEncode(await atAccessLog?.mostVisitedKeys(length));
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
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(atServer.currentAtSign));
    var entry = await atAccessLog!.getLastAccessLogEntry();
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
    var atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(atServer.currentAtSign));
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

class NotificationsMetricImpl extends MetricProvider {
  NotificationsMetricImpl(super.atServer);

  String _asString(dynamic enumData) {
    return enumData == null ? 'null' : enumData.toString().split('.')[1];
  }

  @override
  Future<String?> getMetrics({String? regex}) async {
    Map<String, dynamic> metricsMap = <String, dynamic>{
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
    metricsMap = await getNotificationStats(metricsMap);
    return jsonEncode(metricsMap);
  }

  bool _check(var notifications, String key, String? value) {
    return _asString(notifications.toJson()[key]) == value;
  }

  Future<Map<String, dynamic>> getNotificationStats(
      Map<String, dynamic> metrics) async {
    AtNotificationKeystore notificationKeystore =
        AtNotificationKeystore.getInstance();
    List notificationsList = await notificationKeystore.getValues();
    metrics['total'] = notificationsList.length;
    for (var notifications in notificationsList) {
      if (_check(notifications, 'type', 'sent')) {
        metrics['type']['sent']++;
      } else if (_check(notifications, 'type', 'received')) {
        metrics['type']['received']++;
      }
      if (_check(notifications, 'notificationStatus', 'delivered')) {
        metrics['status']['delivered']++;
      } else if (_check(notifications, 'notificationStatus', 'errored')) {
        metrics['status']['failed']++;
      } else if (_check(notifications, 'notificationStatus', 'queued') ||
          _check(notifications, 'status', null)) {
        metrics['status']['queued']++;
      }
      if (_check(notifications, 'opType', 'update')) {
        metrics['operations']['update']++;
      } else if (_check(notifications, 'opType', 'delete')) {
        metrics['operations']['delete']++;
      }
      if (_check(notifications, 'messageType', 'key')) {
        metrics['messageType']['key']++;
      } else if (_check(notifications, 'messageType', 'text')) {
        metrics['messageType']['text']++;
      }
    }
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
    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(atServer.currentAtSign)
        ?.getSecondaryKeyStore();
    if (keyStore!.isKeyExists(AtConstants.commitLogCompactionKey)) {
      AtData? atData = await keyStore.get(AtConstants.commitLogCompactionKey);
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
    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(atServer.currentAtSign)
        ?.getSecondaryKeyStore();
    if (keyStore!.isKeyExists(AtConstants.accessLogCompactionKey)) {
      AtData? atData = await keyStore.get(AtConstants.accessLogCompactionKey);
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
    var keyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(atServer.currentAtSign)
        ?.getSecondaryKeyStore();
    if (keyStore!.isKeyExists(AtConstants.notificationCompactionKey)) {
      AtData? atData =
          await keyStore.get(AtConstants.notificationCompactionKey);
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
    var responseMap = <String, List<dynamic>>{};
    var atCommitLog = await (AtCommitLogManagerImpl.getInstance()
        .getCommitLog(atServer.currentAtSign));

    int? lastCommitId = atCommitLog?.lastCommittedSequenceNumber();
    int lastCommitIdReceived = -1;
    while (lastCommitId != null && lastCommitIdReceived != lastCommitId) {
      Iterator commitEntryIterator =
          atCommitLog!.getEntries(lastCommitIdReceived, regex: regex);
      while (commitEntryIterator.moveNext()) {
        CommitEntry commitEntry = commitEntryIterator.current.value;
        responseMap[commitEntry.atKey!] = [
          commitEntry.commitId,
          commitEntry.operation.name
        ];
        lastCommitIdReceived = commitEntry.commitId!;
      }
    }
    return jsonEncode(responseMap);
  }

  @override
  String getName() {
    return 'LatestCommitEntryOfEachKey';
  }
}
