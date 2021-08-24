import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/response/response_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';

abstract class BaseResponseHandler implements ResponseHandler {
  late var logger;
  BaseResponseHandler() {
    logger = AtSignLogger(runtimeType.toString());
  }

  @override
  Future<void> process(AtConnection connection, Response response) async {
    logger.finer('Got response: $response');
    var result = response.data;
    try {
      if (response.isError || response.isStream) {
        if (response.isError) {
          logger.severe(response.errorMessage);
        }
        return;
      }
      var atConnectionMetadata =
          connection.getMetaData() as InboundConnectionMetadata;
      var isAuthenticated = atConnectionMetadata.isAuthenticated;
      var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      var isPolAuthenticated = connection.getMetaData().isPolAuthenticated;
      var fromAtSign = atConnectionMetadata.fromAtSign;
      var prompt = isAuthenticated
          ? '$atSign@'
          : (isPolAuthenticated ? '$fromAtSign@' : '@');
      var responseMessage = getResponseMessage(result, prompt)!;
      connection.write(responseMessage);
    } on Exception catch (e) {
      logger.severe('exception in writing response to socket:${e.toString()}');
      await GlobalExceptionHandler.getInstance()
          .handle(e, atConnection: connection);
    }
  }

  /// Construct a response message from verb result and the prompt to return to the user
  /// @params - result of the processed [Verb]
  /// @params - prompt to return to the user. e.g. @ or @alice@
  /// @return - response message to write to requesting connection
  String? getResponseMessage(String? verbResult, String prompt);
}
