// ignore_for_file: constant_identifier_names

import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/metrics/metrics_impl.dart';
import 'package:at_secondary/src/verb/metrics/metrics_provider.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

// StatsVerbHandler class is used to process stats verb
// Stats verb will return all the possible keys you can lookup
//Ex: stats\n
enum Metric {
  INBOUND,
  OUTBOUND,
  LASTCOMMIT,
  SECONDARY_STORAGE_SIZE,
  MOST_VISITED_ATSIGN,
  MOST_VISITED_ATKEYS,
  SECONDARY_SERVER_VERSION,
  LAST_LOGGEDIN_DATETIME,
  DISK_SIZE,
  LAST_AUTH_TIME,
  NOTIFICATION_COUNT,
  COMMIT_LOG_COMPACTION,
  ACCESS_lOG_COMPACTION,
  NOTIFICATION_COMPACTION,
  LATEST_COMMIT_ENTRY_OF_EACH_KEY,
  INBOUND_SUMMARY,
  INBOUND_DETAILED,
}

final Map statsMap = {
  '1': Metric.INBOUND,
  '2': Metric.OUTBOUND,
  '3': Metric.LASTCOMMIT,
  '4': Metric.SECONDARY_STORAGE_SIZE,
  '5': Metric.MOST_VISITED_ATSIGN,
  '6': Metric.MOST_VISITED_ATKEYS,
  '7': Metric.SECONDARY_SERVER_VERSION,
  '8': Metric.LAST_LOGGEDIN_DATETIME,
  '9': Metric.DISK_SIZE,
  '10': Metric.LAST_AUTH_TIME,
  '11': Metric.NOTIFICATION_COUNT,
  '12': Metric.COMMIT_LOG_COMPACTION,
  '13': Metric.ACCESS_lOG_COMPACTION,
  '14': Metric.NOTIFICATION_COMPACTION,
  '15': Metric.LATEST_COMMIT_ENTRY_OF_EACH_KEY,
  '16': Metric.INBOUND_SUMMARY,
  '17': Metric.INBOUND_DETAILED,
};

class StatsVerbHandler extends AbstractVerbHandler {
  // Composition-root access (deliberate): the stats metrics operate over
  // server-wide state, so each Metric implementation below takes the whole
  // server instance.
  AtSecondaryServerImpl atServer = AtSecondaryServerImpl.getInstance();
  static Stats stats = Stats();

  dynamic _regex;

  MetricProvider getProvider(Metric metric) {
    switch (metric) {
      case Metric.INBOUND:
        return InboundMetricImpl(atServer);
      case Metric.OUTBOUND:
        return OutBoundMetricImpl(atServer);
      case Metric.LASTCOMMIT:
        return LastCommitIDMetricImpl(atServer);
      case Metric.SECONDARY_STORAGE_SIZE:
        return SecondaryStorageMetricImpl(atServer);
      case Metric.MOST_VISITED_ATSIGN:
        return MostVisitedAtSignMetricImpl(atServer);
      case Metric.MOST_VISITED_ATKEYS:
        return MostVisitedAtKeyMetricImpl(atServer);
      case Metric.SECONDARY_SERVER_VERSION:
        return SecondaryServerVersion(atServer);
      case Metric.LAST_LOGGEDIN_DATETIME:
        return LastLoggedInDatetimeMetricImpl(atServer);
      case Metric.DISK_SIZE:
        return DiskSizeMetricImpl(atServer);
      case Metric.LAST_AUTH_TIME:
        return LastPkamMetricImpl(atServer);
      case Metric.NOTIFICATION_COUNT:
        return NotificationsMetricImpl(atServer);
      case Metric.COMMIT_LOG_COMPACTION:
        return CommitLogCompactionStats(atServer);
      case Metric.ACCESS_lOG_COMPACTION:
        return AccessLogCompactionStats(atServer);
      case Metric.NOTIFICATION_COMPACTION:
        return NotificationCompactionStats(atServer);
      case Metric.LATEST_COMMIT_ENTRY_OF_EACH_KEY:
        return LatestCommitEntryOfEachKey(atServer);
      case Metric.INBOUND_SUMMARY:
        return InboundSummaryMetricImpl(atServer);
      case Metric.INBOUND_DETAILED:
        return InboundDetailedMetricImpl(atServer);
    }
  }

  StatsVerbHandler(super.keyStore, super.context);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.stats));

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return stats;
  }

  Future<void> addStatToResult(
      id, result, List<String> enrolledNamespaces) async {
    logger.info('addStatToResult for id : $id, regex: $_regex');
    Metric metric = metricById(id);
    MetricProvider provider = getProvider(metric);
    dynamic value;
    if (id == '3') {
      if (_regex == null || _regex.isEmpty) {
        _regex = '.*';
      }
      // When connection is authenticated via the APKAM, return the highest commit-Id
      // among the specified namespaces.
      value = await (provider as LastCommitIDMetricImpl)
          .getMetrics(regex: _regex, enrolledNamespaces: enrolledNamespaces);
    } else if (id == '15' && _regex != null) {
      value = await provider.getMetrics(regex: _regex);
    } else {
      value = await provider.getMetrics();
    }
    var stat = Stat(id, provider.getName(), value);
    result.add(jsonEncode(stat));
  }

  // Method which will process stats Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var statID = verbParams[AtConstants.statId];
    _regex = verbParams[AtConstants.regex];
    logger.finer('In statsVerbHandler statID : $statID, regex : $_regex');
    Set statsList;
    if (statID != null) {
      //If user provides stats ID's create set out of it
      statsList = getStatsIDSet(statID);
    } else {
      // if user send only stats verb get list of all the stat ID's
      statsList = statsMap.keys.toSet();
    }
    var result = [];
    List<String> enrolledNamespaces = [];
    if ((atConnection.metaData as InboundConnectionMetadata).enrollmentId !=
        null) {
      enrolledNamespaces = (await atServer.enrollmentManager.getEnrollmentById(
              (atConnection.metaData as InboundConnectionMetadata)
                  .enrollmentId!))
          .namespaces
          .keys
          .toList();
    }
    //Iterate through stats_id_list
    await Future.forEach(
        statsList,
        (dynamic element) =>
            addStatToResult(element, result, enrolledNamespaces));
    // Create response json
    var responseJson = result.toString();
    response.data = responseJson;
  }

  // get Metric based on ID
  Metric metricById(String key) {
    //use map and get name based on ID
    if (statsMap.containsKey(key)) {
      return statsMap[key];
    } else {
      throw InvalidSyntaxException('No metric with ID $key');
    }
  }

  // Method to get stat ID set form input
  // create set using comma separated ID's. duplicates not allowed
  Set getStatsIDSet(String statID) {
    var startIndex = statID.indexOf(':');
    statID = statID.substring(startIndex + 1);
    var statIDList = statID.split(',');
    var statIDSet = statIDList.toSet();
    return statIDSet;
  }
}

// Stat class is for individual metric
class Stat {
  dynamic id;
  dynamic name;
  dynamic value;

  Stat(this.id, this.name, this.value);

  Map toJson() => {'id': id, 'name': name, 'value': value};
}
