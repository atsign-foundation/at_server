import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// [StatsNotificationService] is a singleton class that notifies the latest commitID
/// to the active monitor connections.
/// The schedule job runs at a time interval specified in [notification][statsNotificationJobTimeInterval]
/// in [config.yaml]. Defaults to 15 seconds.
/// To disable the service, set [notification][statsNotificationJobTimeInterval] in [config.yaml] to -1.
/// The [schedule] method is invoked during the server start-up and should be called only
/// once.
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
  final String _currentAtSign =
      AtSecondaryServerImpl.getInstance().currentAtSign;
  var _atCommitLog;

  /// Starts the [StatsNotificationService] and notifies the latest commitID
  /// to the active monitor connections.
  /// The [AtSecondaryConfig.statsNotificationJobTimeInterval] represents the time interval between the jobs.
  void schedule() async {
    // If set to -1, the feature is disabled. Do nothing.
    if (AtSecondaryConfig.statsNotificationJobTimeInterval == -1) {
      _logger.info('StatsNotificationService is disabled');
      return;
    }
    _atCommitLog =
        await AtCommitLogManagerImpl.getInstance().getCommitLog(_currentAtSign);
    // Setting while(true) to form an infinite loop.
    // Runs the _schedule method as long as server is up and running.
    while (true) {
      await Future.delayed(
          Duration(seconds: AtSecondaryConfig.statsNotificationJobTimeInterval),
          _schedule);
    }
  }

  Future<void> _schedule() async {
    _logger.info('StatsNotificationService started');
    try {
      await _writeStatsToMonitor();
    } finally {
      _logger.info('StatsNotificationService completed');
    }
  }

  Future<void> _writeStatsToMonitor() async {
    // Gets the list of active connections.
    var connectionsList = InboundConnectionPool.getInstance().getConnections();
    // Iterates on the list of active connections.
    await Future.forEach(connectionsList, (InboundConnection connection) async {
      // If a monitor connection is stale for 15 seconds,
      // Writes the lastCommitID to the monitor connection
      if (connection.isMonitor != null &&
          connection.isMonitor! &&
          DateTime.now()
                  .toUtc()
                  .difference(connection.getMetaData().lastAccessed!)
                  .inSeconds >=
              AtSecondaryConfig.statsNotificationJobTimeInterval) {
        //Construct a stats notification
        var atNotificationBuilder = AtNotificationBuilder()
          ..id = '-1'
          ..fromAtSign = _currentAtSign
          ..notification = 'statsNotification.$_currentAtSign'
          ..toAtSign = _currentAtSign
          ..notificationDateTime = DateTime.now().toUtc()
          ..opType = OperationType.update
          ..atValue = _atCommitLog!.lastCommittedSequenceNumber().toString();
        var notification = Notification(atNotificationBuilder.build());
        _logger.info(
            'writing stats notification to connection - SessionID: ${connection.getMetaData().sessionID}');
        connection
            .write('notification: ' + jsonEncode(notification.toJson()) + '\n');
      }
    });
  }
}
