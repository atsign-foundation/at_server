import 'package:at_commons/at_commons.dart';
import 'package:at_root_server/src/server/at_root_config.dart';
import 'package:at_root_server/src/server/root_server_bootstrapper.dart';
import 'package:at_utils/at_logger.dart';

Future<void> main(List<String> arguments) async {
  var isDebug = AtRootConfig.debugLog;
  AtSignLogger.defaultLoggingHandler = AtSignLogger.stdErrLoggingHandler;
  if (isDebug) {
    AtSignLogger.root_level = 'finest';
  }
  var logger = AtSignLogger('main');

  try {
    await RootServerBootStrapper(arguments).run();
  } on AtServerException catch (exception) {
    logger.severe('Exception while starting root server:${exception.message}');
  } catch (exception) {
    logger
        .severe('Exception while starting root server:${exception.toString()}');
  }
}
