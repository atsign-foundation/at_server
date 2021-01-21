import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/at_server_spec.dart';

// BatchVerbHandler is used to process batch of commands
class BatchVerbHandler extends AbstractVerbHandler {
  static Batch batch = Batch();

  BatchVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.batch) + ':');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return batch;
  }

  @override
  HashMap<String, String> parse(String command) {
    var verbParams = super.parse(command);
    return verbParams;
  }

  // Method which will process update Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    var batchCommand = verbParams['json'];
    var batchJson = jsonDecode(batchCommand);
    //handle invalid json
    var batchResponses = <BatchResponse>[];
    for (var value in batchJson) {
      var batchId = value['id'];
      var command = value['command'];
      var handlerManager =
          DefaultVerbHandlerManager(); //gets instance of singleton
      var verbHandler = handlerManager.getVerbHandler(command);
      if (verbHandler is AbstractVerbHandler) {
        try {
          var response =
              await verbHandler.processInternal(command, atConnection);
          var batchResponse = BatchResponse(batchId, response);
          batchResponses.add(batchResponse);
        } on Exception catch (e) {
          var response = Response();
          response.errorCode =
              GlobalExceptionHandler.getInstance().getErrorCode(e);
          if (response.errorCode != null) {
            response.errorMessage = GlobalExceptionHandler.getInstance()
                .getErrorDescription(response.errorCode);
            var batchResponse = BatchResponse(batchId, response);
            batchResponses.add(batchResponse);
          } else {
            logger.severe(
                'No error code found. Exception executing command in a batch. ${e.toString()}');
          }
        }
      }
    }
    response.data = jsonEncode(batchResponses);
  }
}
