import 'package:at_root_server/src/at_security_context_impl.dart';
import 'package:at_root_server/src/command_line_utils.dart';
import 'package:at_root_server/src/server/at_root_config.dart';
import 'package:at_root_server/src/server/at_root_server_impl.dart';
import 'package:at_root_server/src/server/server_context.dart';
import 'package:at_persistence_root_server/at_persistence_root_server.dart';
import 'package:at_utils/at_logger.dart';

class RootServerBootStrapper {
  final logger = AtSignLogger('RootServerBootStrapper');

  late final AtRootServerContext _rootContext;

  AtRootServerContext get rootContext => _rootContext;

  RootServerBootStrapper(List<String> args) {
    _rootContext = createAtRootServerContext(args);
  }

  static AtRootServerContext createAtRootServerContext(List<String> args) {
    final AtRootServerContext c = AtRootServerContext();

    c.port = AtRootConfig.rootServerPort;
    c.httpsPort = AtRootConfig.httpsPort;
    c.httpsEnabled = AtRootConfig.httpsEnabled;

    var results = CommandLineParser().getParserResults(args);
    c.redisServerHost = results['redis_host'];
    c.redisServerPort = int.parse(results['redis_port']);
    c.redisAuth = results['redis_auth'];

    if (AtRootConfig.useSSL) {
      c.securityContext = AtRootSecurityContextImpl();
    }

    return c;
  }

  Future<void> run() async {
    // Initialize the ConnectionManager for the key store with redisHost and port
    var redisManager = RedisConnectionManager.getInstance();
    await redisManager.init(rootContext.redisServerHost!,
        rootContext.redisServerPort!, rootContext.redisAuth!);
    var keyStoreManager = KeystoreManagerImpl();
    var result = await (keyStoreManager.getKeyStore().get('ping'));
    logger.info(result);
    assert(result != null && 'pong'.compareTo(result) == 0);
    var serverInstance = RootServerImpl();
    serverInstance.setServerContext(rootContext);
    serverInstance.start();
  }
}
