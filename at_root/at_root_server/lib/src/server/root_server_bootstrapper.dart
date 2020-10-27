import 'package:at_root_server/src/at_security_context_impl.dart';
import 'package:at_root_server/src/command_line_utils.dart';
import 'package:at_root_server/src/server/at_root_config.dart';
import 'package:at_root_server/src/server/at_root_server_impl.dart';
import 'package:at_root_server/src/server/server_context.dart';
import 'package:at_persistence_root_server/at_persistence_root_server.dart';
import 'package:at_utils/at_logger.dart';

class RootServerBootStrapper {
  static final bool useSSL = AtRootConfig.useSSL;
  var arguments;
  var logger = AtSignLogger('RootServerBootStrapper');

  RootServerBootStrapper(this.arguments);

  void run() async {
    try {
      var results = CommandLineParser().getParserResults(arguments);
      var rootContext = AtRootServerContext();
      rootContext.port = AtRootConfig.rootServerPort;
      rootContext.redisServerHost = results['redis_host'];
      rootContext.redisServerPort = int.parse(results['redis_port']);
      rootContext.redisAuth = results['redis_auth'];
      if (useSSL) {
        rootContext.securityContext = AtSecurityContextImpl();
      }
      // Initialize the ConnectionManager for the key store with redisHost and port
      var redisManager = RedisConnectionManager.getInstance();
      await redisManager.init(rootContext.redisServerHost,
          rootContext.redisServerPort, rootContext.redisAuth);
      var keyStoreManager = KeystoreManagerImpl();
      var result = await keyStoreManager.getKeyStore().get('ping');
      logger.info(result);
      assert('pong'.compareTo(result) == 0);
      var serverInstance = RootServerImpl();
      serverInstance.setServerContext(rootContext);
      serverInstance.start();
    } on Exception {
      rethrow;
    }
  }
}
