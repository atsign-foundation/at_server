import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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
  LAST_PKAM,
  NOTIFICATION_COUNT
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
      case MetricNames.LAST_PKAM:
        return LastPkamMetricImpl.getInstance();
      case MetricNames.NOTIFICATION_COUNT:
        return NotificationsMetricImpl.getInstance();
      default:
        return null;
    }
  }
}

final Map stats_map = {
  '1': MetricNames.INBOUND,
  '2': MetricNames.OUTBOUND,
  '3': MetricNames.LASTCOMMIT,
  '4': MetricNames.SECONDARY_STORAGE_SIZE,
  '5': MetricNames.MOST_VISITED_ATSIGN,
  '6': MetricNames.MOST_VISITED_ATKEYS,
  '7': MetricNames.SECONDARY_SERVER_VERSION,
  '8': MetricNames.LAST_LOGGEDIN_DATETIME,
  '9': MetricNames.DISK_SIZE,
  '10': MetricNames.LAST_PKAM,
  '11': MetricNames.NOTIFICATION_COUNT
};

class StatsVerbHandler extends AbstractVerbHandler {
  static Stats stats = Stats();

  var _regex;

  StatsVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.stats));

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return stats;
  }

  Future<void> addStatToResult(id, result) async {
    logger.info('addStatToResult for id : $id, regex: $_regex');
    var metric = _getMetrics(id);
    var name = metric.name!.getName();
    var value;
    if (id == '3' && _regex != null) {
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
      var statID = verbParams[AT_STAT_ID];
      _regex = verbParams[AT_REGEX];
      logger.finer('In statsVerbHandler statID : $statID, regex : $_regex');
      Set stats_list;
      if (statID != null) {
        //If user provides stats ID's create set out of it
        stats_list = getStatsIDSet(statID);
      } else {
        // if user send only stats verb get list of all the stat ID's
        stats_list = stats_map.keys.toSet();
      }
      var result = [];
      //Iterate through stats_id_list
      await Future.forEach(
          stats_list, (dynamic element) => addStatToResult(element, result));
      // Create response json
      var response_json = result.toString();
      response.data = response_json;
    } catch (exception) {
      response.isError = true;
      response.errorMessage = exception.toString();
      return;
    }
  }

  // get Metric based on ID
  MetricNames? _getMetrics(String key) {
    //use map and get name based on ID
    if (stats_map.containsKey(key)) {
      return stats_map[key];
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
  var id;
  var name;
  var value;

  Stat(this.id, this.name, this.value);

  Map toJson() => {'id': id, 'name': name, 'value': value};
}
