import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/response/response_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

abstract class BaseResponseHandler implements ResponseHandler {
  late AtSignLogger logger;
  BaseResponseHandler() {
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
          connection.getMetaData() as InboundConnectionMetadata;
      var isAuthenticated = atConnectionMetadata.isAuthenticated;
      var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      var isPolAuthenticated = connection.getMetaData().isPolAuthenticated;
      var fromAtSign = atConnectionMetadata.fromAtSign;
      var prompt = isAuthenticated
          ? '$atSign@'
          : (isPolAuthenticated ? '$fromAtSign@' : '@');
      String? responseMessage;
      if (response.isError) {
        var errorJsonMap = {
          'errorCode': response.errorCode,
          'errorDescription':
              '${error_description[response.errorCode]} : ${response.errorMessage}'
        };
        logger.severe(response.errorMessage);
        responseMessage = 'error:${jsonEncode(errorJsonMap)}\n$prompt';
      } else {
        responseMessage = getResponseMessage(result, prompt)!;
      }
      connection.write(responseMessage);
    } on Exception catch (e, st) {
      logger.severe('exception in writing response to socket:${e.toString()}');
      await GlobalExceptionHandler.getInstance()
          .handle(e, stackTrace: st, atConnection: connection);
    }
  }

  /// Construct a response message from verb result and the prompt to return to the user
  /// @params - result of the processed [Verb]
  /// @params - prompt to return to the user. e.g. @ or @alice@
  /// @return - response message to write to requesting connection
  String? getResponseMessage(String? verbResult, String prompt);
}
