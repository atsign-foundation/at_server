import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/connection_metrics.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/regex_util.dart';
import 'package:at_secondary/src/verb/metrics/metrics_provider.dart';

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
  String getMetrics({String? regex}) {
    logger.finer('In commitID getMetrics...regex : $regex');
    var lastCommitID;
    if (regex != null) {
      lastCommitID =
          _atCommitLog.lastCommittedSequenceNumberWithRegex(regex).toString();
      return lastCommitID;
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
    return jsonEncode(atAccessLog?.mostVisitedAtSigns(length));
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
    return jsonEncode(atAccessLog?.mostVisitedKeys(length));
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
    AtAccessLog? atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    var entry = atAccessLog!.getLastAccessLogEntry();
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
    var storageLocation = Directory(AtSecondaryServerImpl.storagePath!);
    var diskSize = 0;
    //The listSync function returns the list of files in the hive storage location.
    // In the loop iterating recursively into sub-directories and gets the size of each file using lengthSync
    storageLocation.listSync(recursive: true).forEach((file) {
      if (file is File) {
        diskSize =
            diskSize + File(file.path).lengthSync();
      }
    });
    //Return total size
    return formatBytes(diskSize, 2);
  }

  @override
  String getName() {
    return 'diskSize';
  }

  String formatBytes(int bytes, int decimals) {
    if (bytes <= 0) return "0 B";
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];
    var i = (log(bytes)/ log(1024)).floor();
    return ((bytes / pow(1024, i)).toStringAsFixed(decimals)) +
        ' ' +
        suffixes[i];
  }
}

class LastPkamMetricImpl implements MetricProvider {
  static final LastPkamMetricImpl _singleton =
  LastPkamMetricImpl._internal();

  LastPkamMetricImpl._internal();

  factory LastPkamMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<String?> getMetrics({String? regex}) async {
    AtAccessLog? atAccessLog = await (AtAccessLogManagerImpl.getInstance()
        .getAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    var entry = atAccessLog!.getLastPkamAccessLogEntry();
    return (entry!= null) ? entry.requestDateTime!.toUtc().toString() : 'Not Available';
  }

  @override
  String getName() {
    return 'LastPkam';
  }
}
