import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:cron/cron.dart';
import 'package:meta/meta.dart';

/// [AtCertificateValidationJob] rebinds the new certificates to at_secondary server.
/// The process for refreshing the certificates is:
/// - Replace the old certificates with new certificates in the certs location.
/// - Place the restart file in the certificates location which indicates the server that new certificates are available.
/// - On detecting the restart file, this class does the following:
///     - If force restart is set to true, the secondary server restarts immediately regardless of whether or not
///     a request is currently being handled.
///     - If force restart is set to false, the secondary server waits for a configurable duration which defaults to [defaultGracefulWaitTimeout].
class AtCertificateValidationJob {
  static final logger = AtSignLogger('AtCertificationValidation');

  /// Default value for [gracefulExitWaitTimeout]
  static const Duration defaultGracefulWaitTimeout = Duration(seconds:30);

  /// The location at which we will find the file which indicates we need to restart
  String restartFilePath;

  /// The secondary server we are going to pause, stop and start
  AtSecondaryServer secondaryServer;

  /// When true, server will be restarted immediately regardless of whether or not a request is currently being handled.
  bool forceRestart;

  /// When a restart is required we pause the server, which prevents new connections being established,
  /// and prevents existing connections from handling new verb requests. We then wait for some duration
  /// for existing requests to complete. Once that duration has passed, we will restart the server.
  /// The value defaults to [defaultGracefulWaitTimeout] and can be overridden by constructor.
  Duration gracefulExitWaitTimeout;

  Cron? _cron;

  AtCertificateValidationJob(
      this.secondaryServer,
      this.restartFilePath,
      this.forceRestart,
      {this.gracefulExitWaitTimeout = defaultGracefulWaitTimeout});

  /// May only be called once. Will throw a StateError if called more than once.
  /// When called, it schedules [checkAndRestartIfRequired] to run every twelve hours
  /// picking a random first hour at which to run.
  Future<void> start() async {
    if (_cron != null) {
      throw StateError('CertificateExpiryCheck cron is already running');
    }
    _cron = Cron();
    // Run the cron job twice a day.
    // Generate a random number between 0 and 11
    var certsJobHour = Random().nextInt(11);
    _cron!.schedule(Schedule(hours: [certsJobHour, certsJobHour + 12]), checkAndRestartIfRequired);
    logger.info("CertificateExpiryCheck cron scheduled - will run (24-hour-clock) at $certsJobHour:00 and ${certsJobHour+12}:00");
  }

  /// To prevent two checks running concurrently
  bool _checkInProgress = false;

  /// This method is called every time the cron job triggers. It checks if a restart is
  /// required and if so, it
  /// - calls [cron.close]
  /// - waits for [waitUntilReadyToRestart]
  /// - waits for [restartServer]
  Future<void> checkAndRestartIfRequired() async
  {
    if (_checkInProgress) {
      logger.info('checkAndRestartIfRequired called - but checkAndRestartIfRequired is already in progress. Returning.');
      return;
    }

    _checkInProgress = true;
    logger.info('checkAndRestartIfRequired called');
    try {
      logger.info('Checking if restart is required');
      bool shouldRestart = await isRestartRequired();
      if (shouldRestart) {
        logger.info('Restart is required');
        if (forceRestart) {
          logger.info('forceRestart is true - will restart immediately');
        } else {
          logger.info('Waiting until ready to restart');
          await waitUntilReadyToRestart();
        }

        logger.info('Restarting secondary server');
        await restartServer();
      } else {
        logger.info('Restart is NOT required. Check complete.');
      }
    } finally {
      _checkInProgress = false;
    }
  }

  Future<bool> isRestartRequired() async {
    return File(restartFilePath).exists();
  }

  @visibleForTesting
  /// Restarts the secondary server by calling secondaryServer.stop() and then secondaryServer.start()
  Future<void> restartServer() async {
    logger.info("restartServer called");

    // Secondary Server start will create a new instance of this job, we need to stop this cron
    logger.info("stopping cron");
    unawaited(_cron!.close());

    logger.info("awaiting secondaryServer.stop()");
    await secondaryServer.stop();

    logger.info("calling secondaryServer.start()");
    secondaryServer.start();
  }

  @visibleForTesting
  /// - Calls secondaryServer.pause() which tells the server that it should not accept
  /// any new connections, should close existing idle connections, should prevent existing connections
  /// from accepting new requests, and should close existing active connections once they have finished
  /// handling whatever they are currently doing
  /// - Immediately, and subsequently every second until the [gracefulExitWaitTimeout] has passed
  ///     - checks count of active connections excluding connections which are sending data to clients
  ///     asynchronously (e.g. monitor connections, fsync connections)
  ///     - If count is 0, return true (we're able to restart gracefully)
  /// - If the gracefulExitWaitTimeout has passed, we need to restart anyway. Return false
  Future<bool> waitUntilReadyToRestart() async {
    AtSecondaryServerImpl.getInstance().pause();

    DateTime gracePeriodEnd = DateTime.now().add(gracefulExitWaitTimeout);

    int monitorSize, totalSize, activeSize;
    while (DateTime.now().toUtc().microsecondsSinceEpoch < gracePeriodEnd.microsecondsSinceEpoch) {
      monitorSize = ConnectionUtil.getMonitorConnectionSize();
      totalSize = ConnectionUtil.getActiveConnectionSize();
      activeSize = totalSize - monitorSize;
      logger.info('Active connections $activeSize ($totalSize total, $monitorSize monitor(s))');
      if (totalSize == 0 || totalSize == monitorSize) {
        logger.info('No active connections except for asynchronous connections - OK to restart server');
        return true;
      } else {
        await Future.delayed(Duration(seconds: 1));
      }
    }
    monitorSize = ConnectionUtil.getMonitorConnectionSize();
    totalSize = ConnectionUtil.getActiveConnectionSize();
    activeSize = totalSize - monitorSize;
    logger.warning('gracefulExitWaitTimeout $gracefulExitWaitTimeout has passed. Will restart server even though we may have active connections');
    logger.info('Active connections $activeSize ($totalSize total, $monitorSize monitor(s))');
    return false;
  }

  Future<void> deleteRestartFile() async {
    var file = File(restartFilePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> createRestartFile() async {
    var file = File(restartFilePath);
    if (! await file.exists()) {
      await file.create();
    }
  }
}
