import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart' show AtConstants;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Used to guard state of this service
enum StatsNotificationServiceState {
  /// Periodic job not currently running. Can call [schedule] to start
  notScheduled,

  /// [schedule] has been called but has not yet completed
  scheduling,

  /// Job has been scheduled to run periodically. To cancel, call [cancel].
  /// When [cancel] is called, the state will reset to [notScheduled]
  scheduled
}

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

  static final Duration zeroDuration = Duration(microseconds: 0);

  @visibleForTesting
  StatsNotificationServiceState state =
      StatsNotificationServiceState.notScheduled;

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
  Future<void> schedule(String currentAtSign, AtCommitLog atCommitLog,
      {Duration? interval}) async {
    interval ??=
        Duration(seconds: AtSecondaryConfig.statsNotificationJobTimeInterval);

    // We interpret an interval of less than zero duration to mean that this service should not run.
    if (interval < Duration.zero) {
      _logger
          .info('Interval ($interval) is less than zero - will not schedule.');
      return;
    }
    switch (state) {
      case StatsNotificationServiceState.notScheduled:
        break;
      case StatsNotificationServiceState.scheduling:
        throw StateError(
            'This StatsNotificationService job is in the process of being scheduled');
      case StatsNotificationServiceState.scheduled:
        throw StateError(
            'This StatsNotificationService job has already been scheduled');
    }
    state = StatsNotificationServiceState.scheduling;

    _logger.info('StatsNotificationService is enabled. Runs every $interval');
    this.currentAtSign = currentAtSign;
    this.atCommitLog = atCommitLog;

    // Runs the _schedule method as long as server is up and running.
    timer = Timer.periodic(interval, (timer) async {
      try {
        _logger.finer('Stats Notification Job triggered');
        await writeStatsToMonitor();
        _logger.finer('Stats Notification Job completed');
      } catch (e) {
        _logger.severe('Exception while writing stats: $e');
      }
    });
    state = StatsNotificationServiceState.scheduled;
  }

  cancel() {
    _logger.info('cancel() called');
    timer?.cancel();
    timer = null;
    state = StatsNotificationServiceState.notScheduled;
  }

  /// Writes the lastCommitID to all Monitor connections
  Future<void> writeStatsToMonitor(
      {String? latestCommitID, String? operationType}) async {
    latestCommitID ??= atCommitLog!.lastCommittedSequenceNumber().toString();
    // Gets the list of active connections.
    var connectionsList = AtSecondaryServerImpl.getInstance()
        .inboundConnectionManager
        .pool
        .getConnections();
    if (connectionsList.isEmpty) {
      _logger.finer('No stats written. (No connections.)');
      return;
    }
    // For each inbound connection: if it is a monitor, write stats
    int numOfMonitorConn = 0;
    final notifJsonEncoded = jsonEncode({
      AtConstants.id: '-1',
      AtConstants.from: currentAtSign,
      AtConstants.to: currentAtSign,
      AtConstants.key: 'statsNotification.$currentAtSign',
      AtConstants.value: latestCommitID,
      AtConstants.operation: SecondaryUtil.getOperationType(operationType).name,
      AtConstants.epochMilliseconds: DateTime.now().millisecondsSinceEpoch,
      AtConstants.messageType: MessageType.key.toString(),
      AtConstants.isEncrypted: false,
      // "metadata": metadata
    });
    for (var connection in connectionsList) {
      if (connection.isMonitor ?? false) {
        numOfMonitorConn++;
        try {
          // Convert notification object to JSON and write to connection
          await connection.write('notification:'
              ' $notifJsonEncoded\n');
        } catch (e) {
          _logger.severe('Exception occurred when writing stats to'
              ' inbound connection session ${connection.metaData.sessionID}'
              ' : ${e.toString()}');
        }
      }
    }
    if (numOfMonitorConn == 0) {
      _logger.finer('No stats written. (No monitor connections.)');
    } else {
      _logger.info('Wrote stats to $numOfMonitorConn monitor connections');
    }
  }
}
