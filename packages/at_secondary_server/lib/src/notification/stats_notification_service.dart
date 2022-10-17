import 'dart:async';
import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_utils/at_logger.dart';

/// [StatsNotificationService] is a singleton class that notifies the latest commitID
/// to the active monitor connections.
/// The schedule job runs at a time interval specified in [notification][statsNotificationJobTimeInterval]
/// in [config.yaml]. Defaults to 15 Seconds.
/// To disable the service, set [notification][statsNotificationJobTimeInterval] in [config.yaml] to -1.
/// The [schedule] method is invoked during the server start-up and should be called only
/// once.
/// NOTE: THE CHANGE IN TIME INTERVAL AFFECTS THE SYNC PERFORMANCE.
/// The at_client_sdk gets the latest commit of server via the stats notification service.
/// Sample JSON written to monitor connection.
/// {
///    "id":"c0d8a7d6-5689-476b-b5db-28b4f77e4663",
///    "from":"@alice",
///    "to":"@alice",
///    "key":"statsNotification.monitorKey",
///    "value":"11",
///    "operation":"update",
///    "epochMillis":1628512387184
/// }
class StatsNotificationService {
  static final StatsNotificationService _singleton =
      StatsNotificationService._internal();

  StatsNotificationService._internal();

  factory StatsNotificationService.getInstance() {
    return _singleton;
  }

  final _logger = AtSignLogger('StatsNotificationService');
  late String currentAtSign;
  AtCommitLog? atCommitLog;
  InboundConnectionPool inboundConnectionPool =
      InboundConnectionPool.getInstance();

  // Counter for number of active monitor connections. Used for logging purpose.
  int numOfMonitorConn = 0;

  Notification notification = Notification.empty();

  /// Starts the [StatsNotificationService] and notifies the latest commitID
  /// to the active monitor connections.
  /// The [AtSecondaryConfig.statsNotificationJobTimeInterval] represents the time interval between the jobs.
  Future<void> schedule(String currentAtSign) async {
    // If set to -1, the feature is disabled. Do nothing.
    if (AtSecondaryConfig.statsNotificationJobTimeInterval == -1) {
      _logger.info('StatsNotificationService is disabled');
      return;
    }
    _logger.info(
        'StatsNotificationService is enabled. Runs every ${AtSecondaryConfig.statsNotificationJobTimeInterval} seconds');
    this.currentAtSign = currentAtSign;
    atCommitLog ??=
        await AtCommitLogManagerImpl.getInstance().getCommitLog(currentAtSign);

    // Runs the _schedule method as long as server is up and running.
    Timer.periodic(
        Duration(seconds: AtSecondaryConfig.statsNotificationJobTimeInterval),
        (timer) {
      try {
        _logger.finer('Stats Notification Job triggered');
        writeStatsToMonitor();
        _logger.finer('Stats Notification Job completed');
      } on Exception catch (exception) {
        _logger.severe(
            'Exception occurred when writing stats ${exception.toString()}');
      } on Error catch (error) {
        _logger.severe('Error occurred when writing stats ${error.toString()}');
      }
    });
  }

  /// Writes the lastCommitID to the monitor connection for every [AtSecondaryConfig.statsNotificationJobTimeInterval] seconds. Defaulted to 15 seconds
  void writeStatsToMonitor({String? latestCommitID, String? operationType}) {
    try {
      latestCommitID ??= atCommitLog!.lastCommittedSequenceNumber().toString();
      // Gets the list of active connections.
      var connectionsList = inboundConnectionPool.getConnections();
      // Iterates on the list of active connections.
      for (var connection in connectionsList) {
        if (connection.isMonitor != null && connection.isMonitor!) {
          numOfMonitorConn = numOfMonitorConn + 1;
          // Set notification fields
          notification
            ..id = '-1'
            ..fromAtSign = currentAtSign
            ..notification = 'statsNotification.$currentAtSign'
            ..toAtSign = currentAtSign
            ..dateTime = DateTime.now().toUtc().millisecondsSinceEpoch
            ..operation = SecondaryUtil.getOperationType(operationType)
                .toString()
                .replaceAll('OperationType.', '')
            ..value = latestCommitID
            ..messageType = MessageType.key.toString()
            ..isTextMessageEncrypted = false;
          // Convert notification object to JSON and write to connection
          connection
              .write('notification: ${jsonEncode(notification.toJson())}\n');
        }
      }
      if (numOfMonitorConn == 0) {
        _logger.finer(
            'No monitor connections found. Skipping writing stats to monitor connection');
      }
    } finally {
      numOfMonitorConn = 0;
    }
  }
}
