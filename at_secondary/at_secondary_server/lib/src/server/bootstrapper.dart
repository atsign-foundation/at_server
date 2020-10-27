import 'package:at_secondary/src/arg_utils.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/at_security_context_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_utils/at_utils.dart';
import 'package:at_utils/at_logger.dart';

/// The bootstrapper class for initializing the secondary server configuration parameters from [config.yaml]
/// and call the start method to start the secondary server.
class SecondaryServerBootStrapper {
  var arguments;
  static final bool useSSL = AtSecondaryConfig.useSSL;
  static final int inbound_max_limit = AtSecondaryConfig.inbound_max_limit;
  static final int outbound_max_limit = AtSecondaryConfig.outbound_max_limit;
  static final int inbound_idletime_millis =
      AtSecondaryConfig.inbound_idletime_millis;
  static final int outbound_idletime_millis =
      AtSecondaryConfig.outbound_idletime_millis;

  SecondaryServerBootStrapper(this.arguments);

  var logger = AtSignLogger('SecondaryServerBootStrapper');

  /// Loads the default configurations from [config.yaml] and initiates a call to secondary server start method.
  /// Throws any exceptions back to the calling method.
  void run() async {
    try {
      var results = CommandLineParser().getParserResults(arguments);
      var secondaryContext = AtSecondaryContext();
      secondaryContext.port = int.parse(results['server_port']);
      secondaryContext.currentAtSign = AtUtils.fixAtSign(results['at_sign']);
      secondaryContext.sharedSecret = results['shared_secret'];
      secondaryContext.inboundConnectionLimit = inbound_max_limit;
      secondaryContext.outboundConnectionLimit = outbound_max_limit;
      secondaryContext.inboundIdleTimeMillis = inbound_idletime_millis;
      secondaryContext.outboundIdleTimeMillis = outbound_idletime_millis;
      if (useSSL) {
        secondaryContext.securityContext = AtSecurityContextImpl();
      }

      // Start the secondary server
      var secondaryServerInstance = AtSecondaryServerImpl.getInstance();
      secondaryServerInstance.setServerContext(secondaryContext);
      secondaryServerInstance.setExecutor(DefaultVerbExecutor());
      secondaryServerInstance
          .setVerbHandlerManager(DefaultVerbHandlerManager());
      await secondaryServerInstance.start();
    } on Exception {
      rethrow;
    }
  }
}
