import 'dart:io';
import 'dart:isolate';

import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_logger.dart';
import 'package:pedantic/pedantic.dart';

///[AtCertificateValidationJob] rebinds the new certificates to at_secondary server.
/// 1. Replace the old certificates with new certificates in the certs location.
/// 2. Place the restart file in the certificates location which indicates the server that new certificates are available.
/// 3. On detecting the restart file:
///       a. If force restart is set to true:
///               The secondary server restarts immediately terminating all the active connections.
///       b. If force restart is set to false:
///               The secondary server waits until all the active connections become zero or the total number of active
///               connections equals the number of active connections that run the monitor verb.
class AtCertificateValidationJob {
  static final AtCertificateValidationJob _singleton =
      AtCertificateValidationJob._internal();

  var logger = AtSignLogger('AtCertificationValidation');
  var restartFile = 'restart';
  var filePath = AtSecondaryConfig.certificateChainLocation;
  var isCertificateExpired = false;

  AtCertificateValidationJob._internal();

  factory AtCertificateValidationJob.getInstance() {
    return _singleton;
  }

  /// Spawns an isolate job to verify for the expiry of certificates.
  Future<void> runCertificateExpiryCheckJob() async {
    filePath = filePath!.replaceAll('fullchain.pem', '');
    var mainIsolateReceivePort = ReceivePort();
    SendPort? childIsolateSendPort;
    var isolate = await Isolate.spawn(
        _verifyChangeInCertificate, [mainIsolateReceivePort.sendPort]);
    mainIsolateReceivePort.listen((data) async {
      if (childIsolateSendPort == null && data is SendPort) {
        childIsolateSendPort = data;
        childIsolateSendPort!.send(filePath);
      } else {
        if (data == null) {
          return;
        }
        isCertificateExpired = data;
        isolate.kill();
        _initializeRestartProcess(null);
      }
    });
  }

  /// Isolate job to verify certificates expiry. Sends [true] to main isolate upon creation of [restart] file which acts as a trigger
  /// to indicate the new certificates are in place.
  static void _verifyChangeInCertificate(List<SendPort> commList) async {
    var childIsolateReceivePort = ReceivePort();
    var mainIsolateSendPort = commList[0];
    mainIsolateSendPort.send(childIsolateReceivePort.sendPort);
    childIsolateReceivePort.listen((message) {
      var filePath = message;
      var directory = Directory(filePath);
      var fileSystemEvent = directory.watch(events: FileSystemEvent.create);
      fileSystemEvent.listen((event) {
        if (event.path == filePath + 'restart') {
          mainIsolateSendPort.send(true);
        }
      });
    });
  }

  /// Restarts the secondary server.
  Future<void> _restartServer() async {
    var secondary = AtSecondaryServerImpl.getInstance();
    await secondary.stop();
    await secondary.start();
  }

  dynamic _initializeRestartProcess(_) async {
    //Pause the server to prevent it from accepting any incoming connections
    AtSecondaryServerImpl.getInstance().pause();
    var isForceRestart = AtSecondaryConfig.isForceRestart!;
    if (isForceRestart) {
      logger.info('Initializing force restart on secondary server');
      _deleteRestartFile(filePath! + restartFile);
      await _restartServer();
      return;
    }
    var stopWaiting = false;
    var monitorSize = ConnectionUtil.getMonitorConnectionSize();
    logger.info(
        'Waiting for total number of active connections to 0 or equal to number of monitor connections');
    logger.info('Total number of monitor connections are $monitorSize');
    var totalSize = ConnectionUtil.getActiveConnectionSize();
    logger.info('Total number of active connections are $totalSize');
    if (totalSize == 0 || totalSize == monitorSize) {
      // Setting stopWaiting to true to prevent server start-up process into loop.
      stopWaiting = true;
      _deleteRestartFile(filePath! + restartFile);
      logger.severe('Certificates expired. Restarting secondary server');
      await _restartServer();
    }
    if (!stopWaiting) {
      // Calls _initializeRestartProcess method for every 10 seconds until totalConnections are 0 or
      //totalConnections equals total monitor connections.
      await Future.delayed(Duration(seconds: 10), () {})
          .then(_initializeRestartProcess);
    }
  }

  void _deleteRestartFile(String restartFile) {
    var file = File(restartFile);
    try {
      file.deleteSync();
    } on Exception catch (exception) {
      logger.info('Failed to delete the restart file : $exception');
    }
  }
}
