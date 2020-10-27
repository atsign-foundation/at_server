import 'package:at_server_spec/at_server_spec.dart';

abstract class VerbHandler {
  /// Returns true if a verb handler can accept this command.
  /// @param command - at protocol command
  /// @returns bool
  bool accept(String command);

  ///Processes a given command from a inboundConnection
  ///@param command - at protocol command
  ///@param inboundConnection - requesting [InboundConnection]
  Future<void> process(String command, InboundConnection inboundConnection);
}

abstract class VerbHandlerManager {
  /// Returns the verb handler for a given command
  /// @param utf8 encoded command
  /// @returns [VerbHandler]
  VerbHandler getVerbHandler(String utf8EncodedCommand);
}

abstract class VerbExecutor {
  /// Runs a command requested by from connection using a verb manager
  /// @params utf8EncodedCommand - command to execute
  /// @params fromConnection - requesting [InboundConnection]
  /// @params verbManager - [VerbHandlerManager]
  void execute(String utf8EncodedCommand, InboundConnection fromConnection,
      VerbHandlerManager verbManager);
}
