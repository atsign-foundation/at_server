// ignore_for_file: constant_identifier_names

import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
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
enum MetricNames {
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
  LATEST_COMMIT_ENTRY_OF_EACH_KEY
}

extension MetricClasses on MetricNames? {
  MetricProvider? get name {
    switch (this) {
      case MetricNames.INBOUND:
        return InboundMetricImpl.getInstance();
      case MetricNames.OUTBOUND:
        return OutBoundMetricImpl.getInstance();
      case MetricNames.LASTCOMMIT:
        return LastCommitIDMetricImpl.getInstance();
      case MetricNames.SECONDARY_STORAGE_SIZE:
        return SecondaryStorageMetricImpl.getInstance();
      case MetricNames.MOST_VISITED_ATSIGN:
        return MostVisitedAtSignMetricImpl.getInstance();
      case MetricNames.MOST_VISITED_ATKEYS:
        return MostVisitedAtKeyMetricImpl.getInstance();
      case MetricNames.SECONDARY_SERVER_VERSION:
        return SecondaryServerVersion.getInstance();
      case MetricNames.LAST_LOGGEDIN_DATETIME:
        return LastLoggedInDatetimeMetricImpl.getInstance();
      case MetricNames.DISK_SIZE:
        return DiskSizeMetricImpl.getInstance();
      case MetricNames.LAST_AUTH_TIME:
        return LastPkamMetricImpl.getInstance();
      case MetricNames.NOTIFICATION_COUNT:
        return NotificationsMetricImpl.getInstance();
      case MetricNames.COMMIT_LOG_COMPACTION:
        return CommitLogCompactionStats.getInstance();
      case MetricNames.ACCESS_lOG_COMPACTION:
        return AccessLogCompactionStats.getInstance();
      case MetricNames.NOTIFICATION_COMPACTION:
        return NotificationCompactionStats.getInstance();
      case MetricNames.LATEST_COMMIT_ENTRY_OF_EACH_KEY:
        return LatestCommitEntryOfEachKey();
      default:
        return null;
    }
  }
}

final Map statsMap = {
  '1': MetricNames.INBOUND,
  '2': MetricNames.OUTBOUND,
  '3': MetricNames.LASTCOMMIT,
  '4': MetricNames.SECONDARY_STORAGE_SIZE,
  '5': MetricNames.MOST_VISITED_ATSIGN,
  '6': MetricNames.MOST_VISITED_ATKEYS,
  '7': MetricNames.SECONDARY_SERVER_VERSION,
  '8': MetricNames.LAST_LOGGEDIN_DATETIME,
  '9': MetricNames.DISK_SIZE,
  '10': MetricNames.LAST_AUTH_TIME,
  '11': MetricNames.NOTIFICATION_COUNT,
  '12': MetricNames.COMMIT_LOG_COMPACTION,
  '13': MetricNames.ACCESS_lOG_COMPACTION,
  '14': MetricNames.NOTIFICATION_COMPACTION,
  '15': MetricNames.LATEST_COMMIT_ENTRY_OF_EACH_KEY
};

class StatsVerbHandler extends AbstractVerbHandler {
  static Stats stats = Stats();

  dynamic _regex;

  StatsVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
    var metric = _getMetrics(id);
    var name = metric.name!.getName();
    dynamic value;
    if (id == '3') {
      if (_regex == null || _regex.isEmpty) {
        _regex = '.*';
      }
      // When connection is authenticated via the APKAM, return the highest commit-Id
      // among the specified namespaces.
      value = await (metric.name as LastCommitIDMetricImpl)
          .getMetrics(regex: _regex, enrolledNamespaces: enrolledNamespaces);
    } else if (id == '15' && _regex != null) {
      value = await metric.name!.getMetrics(regex: _regex);
    } else {
      value = await metric.name!.getMetrics();
    }
    var stat = Stat(id, name, value);
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
    try {
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
        var enrollmentKey =
            '${(atConnection.metaData as InboundConnectionMetadata).enrollmentId}.$newEnrollmentKeyPattern.$enrollManageNamespace${AtSecondaryServerImpl.getInstance().currentAtSign}';
        enrolledNamespaces = (await getEnrollDataStoreValue(enrollmentKey))
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
    } catch (exception) {
      response.isError = true;
      response.errorMessage = exception.toString();
      return;
    }
  }

  // get Metric based on ID
  MetricNames? _getMetrics(String key) {
    //use map and get name based on ID
    if (statsMap.containsKey(key)) {
      return statsMap[key];
    } else {
      throw InvalidSyntaxException;
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
