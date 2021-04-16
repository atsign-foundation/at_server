import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class SyncResponseHandler extends BaseResponseHandler {
  @override
  String getResponseMessage(String verbResult, String prompt) {
    var responseMessage;
    if (verbResult == null) {
      return '';
    }
    responseMessage = 'data: $verbResult\n' + prompt;
    return responseMessage;
  }
}
