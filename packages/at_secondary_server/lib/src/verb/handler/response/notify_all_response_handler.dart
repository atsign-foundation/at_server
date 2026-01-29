import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class NotifyAllResponseHandler extends BaseResponseHandler {
  @override
  String? getResponseMessage(String? verbResult, String prompt) {
    String? responseMessage;
    if (verbResult != null) {
      responseMessage = 'data: $verbResult\n$prompt';
    }
    return responseMessage;
  }
}
