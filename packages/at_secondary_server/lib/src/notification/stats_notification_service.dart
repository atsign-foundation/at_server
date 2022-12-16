import 'dart:async';
import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// [StatsNotificationService] is a singleton class that notifies the latest commitID
/// to the active monitor connections.
/// The schedule job runs at a time interval which defaults to the value specified
/// in [AtSecondaryConfig.statsNotificationJobTimeInterval] in [config.yaml]
/// To disable the service, set [AtSecondaryConfig.statsNotificationJobTimeInterval] in [config.yaml] to -1.
/// The [schedule] method is invoked during the server start-up and should be called only
/// once. The [schedule] method takes an optional parameter to allow overriding of the default
/// value for [AtSecondaryConfig.statsNotificationJobTimeInterval]
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

  static final Duration zeroDuration = Duration(microseconds: 0);

  // Counter for number of active monitor connections. Used for logging purpose.
  int numOfMonitorConn = 0;

  Notification notification = Notification.empty();

  @visibleForTesting
  /// Set to true while the job is being scheduled, false once it has been scheduled.
  bool scheduling = false;
  @visibleForTesting
  /// Set to true once the job has been scheduled, false when [cancel] is called.
  bool scheduled = false;

  @visibleForTesting
  /// Timer is created when [schedule] is called successfully. [Timer.cancel] is called
  /// when this class's [cancel] method is called, and [timer] will be set to null.
  Timer? timer;

  /// Starts the [StatsNotificationService] and notifies the latest commitID
  /// to the active monitor connections. By default, [schedule] will write to monitor connections every
  /// [AtSecondaryConfig.statsNotificationJobTimeInterval] seconds. The optional [interval]
  /// parameter is provided so that we can run unit tests using much shorter durations.
  /// Throws a [StateError] If the service is already either [scheduling] or [scheduled].
  /// Creates a periodic Timer which will call the [writeStatsToMonitor] method every [interval]
  /// and sets the [timer] instance variable accordingly.
  Future<void> schedule(String currentAtSign, {Duration? interval}) async {
    interval ??= Duration(seconds: AtSecondaryConfig.statsNotificationJobTimeInterval);

    // We interpret an interval of less than zero duration to mean that this service should not run.
    if (interval < Duration.zero) {
      _logger.info('Interval ($interval) is less than zero - will not schedule.');
      return;
    }
    if (scheduled) {
      throw StateError('This StatsNotificationService job has already been scheduled');
    }
    if (scheduling) {
      throw StateError('This StatsNotificationService job is already being scheduled');
    }
    scheduling = true;
    _logger.info('StatsNotificationService is enabled. Runs every $interval');
    this.currentAtSign = currentAtSign;
    atCommitLog ??= await AtCommitLogManagerImpl.getInstance().getCommitLog(currentAtSign);

    // Runs the _schedule method as long as server is up and running.
    timer = Timer.periodic(interval, (timer) {
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
    scheduled = true;
    scheduling = false;
  }

  cancel() {
    _logger.info('cancel() called');
    timer?.cancel();
    timer = null;
    scheduled = false;
    scheduling = false;
  }

  /// Writes the lastCommitID to all Monitor connections
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
