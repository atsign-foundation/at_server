import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/verb/handler/response/response_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

abstract class BaseResponseHandler implements ResponseHandler {
  /// The atSign this server hosts (used to build the response prompt).
  final Atsign currentAtSign;

  /// Handles exceptions raised while writing the response to the socket.
  final GlobalExceptionHandler exceptionHandler;

  late AtSignLogger logger;

  BaseResponseHandler(this.currentAtSign, this.exceptionHandler) {
    logger = AtSignLogger(runtimeType.toString());
  }

  @override
  Future<void> process(AtConnection connection, Response response) async {
    var result = response.data;
    try {
      if (response.isStream) {
        return;
      }
      var atConnectionMetadata =
          connection.metaData as InboundConnectionMetadata;
      var isAuthenticated = atConnectionMetadata.isAuthenticated;
      var atSign = currentAtSign;
      var isPolAuthenticated = connection.metaData.isPolAuthenticated;
      var fromAtSign = atConnectionMetadata.fromAtSign;
      var prompt = isAuthenticated
          ? '$atSign@'
          : (isPolAuthenticated ? '$fromAtSign@' : '@');
      String? responseMessage;
      if (response.isError) {
        logger.info(response.errorMessage);
        responseMessage =
            'error:${response.errorCode}:${response.errorMessage}\n$prompt';
      } else {
        responseMessage = getResponseMessage(result, prompt)!;
      }
      await connection.write(responseMessage);
    } on Exception catch (e, st) {
      logger.severe('exception in writing response to socket:${e.toString()}');
      await exceptionHandler.handle(e,
          stackTrace: st, atConnection: connection);
    }
  }

  /// Construct a response message from verb result and the prompt to return to the user
  /// @params - result of the processed [Verb]
  /// @params - prompt to return to the user. e.g. @ or @alice@
  /// @return - response message to write to requesting connection
  String? getResponseMessage(String? verbResult, String prompt);
}
