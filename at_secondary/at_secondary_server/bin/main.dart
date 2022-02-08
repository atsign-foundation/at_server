import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/bootstrapper.dart';
import 'package:at_utils/at_logger.dart';

/// The entry method for starting the @Protocol secondary server. Accepts atSign and port as arguments to starts the respective secondary server on
/// given port.
/// Throws [InvalidAtSignException] on invalid atSign.
/// Throws [SocketException] on invalid port.
/// Throws [ArgParserException] for invalid arguments passed.
/// @ param - List<String> atSign and port
Future<void> main(List<String> arguments) async {
  AtSignLogger.root_level = AtSecondaryConfig.logLevel;

  var logger = AtSignLogger('main');

  try {
    var bootStrapper = SecondaryServerBootStrapper(arguments);
    await bootStrapper.run();
  } on Exception catch (e) {
    logger.severe('Exception in starting secondary server: ${e.toString()}');
    await GlobalExceptionHandler.getInstance().handle(e);
  }
}
