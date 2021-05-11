import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_commons/at_commons.dart';

/// The default implementation of [VerbExecutor]
class DefaultVerbExecutor implements VerbExecutor {
  var logger = AtSignLogger('DefaultVerbExecutor');

  /// Accepts the command and gets the appropriate verb handler to process the command.
  /// @param - utf8EncodedCommand: The command in UTF-8 format.
  /// @param - fromConnection: Inbound connection
  /// @param - verbManager: Gets the appropriate verb handler for the command.
  /// Throws [InvalidSyntaxException] if handler is not found for the given command.
  /// Throws [AtConnectException] for connection exception.
  /// Throws [Exception] for exception that occurs in processing the command.
  @override
  Future<void> execute(String utf8EncodedCommand,
      InboundConnection fromConnection, VerbHandlerManager verbManager) async {
    var handler = verbManager.getVerbHandler(utf8EncodedCommand);
    logger.finer('verb handler found : ' + handler.runtimeType.toString());
    if (handler == null) {
      logger.severe('No handler found for command: ${utf8EncodedCommand}');
      throw InvalidSyntaxException('invalid command');
    }
    try {
      await handler.process(utf8EncodedCommand, fromConnection);
    } on AtConnectException {
      rethrow;
    } on Exception catch (e) {
      logger.severe(
          'exception in processing command :${utf8EncodedCommand}: ${e.toString()}');
      rethrow;
    }
  }
}
