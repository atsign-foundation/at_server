import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/arg_utils.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/at_security_context_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_utils/at_utils.dart';

/// The bootstrapper class for initializing the secondary server configuration parameters from [config.yaml]
/// and call the start method to start the secondary server.
class SecondaryServerBootStrapper {
  List<String> arguments;
  static final bool? useTLS = AtSecondaryConfig.useTLS;
  static final int inboundMaxLimit = AtSecondaryConfig.inbound_max_limit;
  static final int outboundMaxLimit = AtSecondaryConfig.outbound_max_limit;
  static final int inboundIdleTimeMillis =
      AtSecondaryConfig.inbound_idletime_millis;
  static final int outboundIdleTimeMillis =
      AtSecondaryConfig.outbound_idletime_millis;

  SecondaryServerBootStrapper(this.arguments);

  var logger = AtSignLogger('SecondaryServerBootStrapper');

  late AtSecondaryServerImpl secondaryServerInstance;

  /// Loads the default configurations from [config.yaml] and initiates a call to secondary server start method.
  /// Throws any exceptions back to the calling method.
  Future<void> run() async {
    secondaryServerInstance = AtSecondaryServerImpl.getInstance();
    try {
      var results = CommandLineParser().getParserResults(arguments);
      var secondaryContext = AtSecondaryContext();
      secondaryContext.port = int.parse(results['server_port']);
      secondaryContext.currentAtSign = AtUtils.fixAtSign(results['at_sign']);
      secondaryContext.sharedSecret = results['shared_secret'];
      secondaryContext.inboundConnectionLimit = inboundMaxLimit;
      secondaryContext.outboundConnectionLimit = outboundMaxLimit;
      secondaryContext.inboundIdleTimeMillis = inboundIdleTimeMillis;
      secondaryContext.outboundIdleTimeMillis = outboundIdleTimeMillis;
      if (useTLS!) {
        secondaryContext.securityContext = AtSecurityContextImpl();
      }
      secondaryContext.trainingMode = results['training'];

      // Start the secondary server
      secondaryServerInstance.setServerContext(secondaryContext);
      secondaryServerInstance.setExecutor(DefaultVerbExecutor());

      //starting secondary in a zone
      //prevents secondary from terminating due to uncaught non-fatal errors
      unawaited(runZonedGuarded(() async {
        await secondaryServerInstance.start();
      }, (error, stackTrace) {
        logger.severe('Uncaught error: $error \n Stacktrace: $stackTrace');
        handleTerminateSignal(ProcessSignal.sigstop);
      }));
      ProcessSignal.sigterm.watch().listen(handleTerminateSignal);
      ProcessSignal.sigint.watch().listen(handleTerminateSignal);
    } on Exception {
      rethrow;
    } on Error {
      rethrow;
    }
  }

  void handleTerminateSignal(event) async {
    try {
      logger.info("Caught $event - calling secondaryServerInstance.stop()");
      await secondaryServerInstance.stop();
      if (secondaryServerInstance.isRunning()) {
        logger.warning(
            "secondaryServerInstance.stop() completed but isRunning still true - exiting with status 1");
        exit(1);
      } else {
        logger.info(
            "secondaryServerInstance.stop() completed, and isRunning is false - exiting with status 0");
        exit(0);
      }
    } on Exception catch (e, stacktrace) {
      logger.warning("Caught $e from secondaryServerInstance.stop() sequence - exiting with status 1");
      logger.warning(stacktrace.toString());
      exit(1);
    } on Error catch (e, stacktrace) {
      logger.warning("Caught $e from secondaryServerInstance.stop() sequence - exiting with status 1");
      logger.warning(stacktrace.toString());
      exit(1);
    } finally {
      logger
          .info("Somehow made it to the finally block - exiting with status 1");
      exit(1);
    }
  }
}
