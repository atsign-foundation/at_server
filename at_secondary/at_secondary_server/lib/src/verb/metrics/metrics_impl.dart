import 'dart:convert';
import 'dart:io';
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
  Future<String> getMetrics({String regex}) async {
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
  Future<String> getMetrics({String regex}) async {
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
  Future<String> getMetrics({String regex}) async {
    logger.finer('In commitID getMetrics...regex : $regex');
    var lastCommitID;
    if (regex != null) {
      lastCommitID = await _atCommitLog
          .lastCommittedSequenceNumberWithRegex(regex)
          .toString();
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
  var secondaryStorageLocation = Directory(AtSecondaryServerImpl.storagePath);

  SecondaryStorageMetricImpl._internal();

  factory SecondaryStorageMetricImpl.getInstance() {
    return _singleton;
  }

  @override
  Future<int> getMetrics({String regex}) async {
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
  Future<String> getMetrics({String regex}) async {
    final length = AtSecondaryConfig.stats_top_visits;
    var atAccessLog;
    if (AtSecondaryConfig.keyStore == 'redis') {
      atAccessLog = await AtAccessLogManagerImpl.getInstance()
          .getRedisAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign,
              AtSecondaryConfig.redisUrl,
              password: AtSecondaryConfig.redisPassword);
    } else {
      atAccessLog = await AtAccessLogManagerImpl.getInstance()
          .getHiveAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign);
    }
    return jsonEncode(atAccessLog.mostVisitedAtSigns(length));
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
  Future<String> getMetrics({String regex}) async {
    final length = AtSecondaryConfig.stats_top_keys;
    var atAccessLog;
    if (AtSecondaryConfig.keyStore == 'redis') {
      atAccessLog = await AtAccessLogManagerImpl.getInstance()
          .getRedisAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign,
              AtSecondaryConfig.redisUrl,
              password: AtSecondaryConfig.redisPassword);
    } else {
      atAccessLog = await AtAccessLogManagerImpl.getInstance()
          .getHiveAccessLog(AtSecondaryServerImpl.getInstance().currentAtSign);
    }
    return jsonEncode(atAccessLog.mostVisitedKeys(length));
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
  Future<String> getMetrics({String regex}) async {
    return AtSecondaryConfig.secondaryServerVersion;
  }

  @override
  String getName() {
    return 'secondaryServerVersion';
  }
}
