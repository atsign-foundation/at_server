import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class FromResponseHandler extends BaseResponseHandler {
  @override
  String getResponseMessage(String? verbResult, String prompt) {
    var responseMessage;
    if (verbResult != null && verbResult.startsWith('proof:')) {
      responseMessage = 'data:$verbResult\n' + prompt;
    } else {
      responseMessage = '$verbResult\n' + prompt;
    }
    return responseMessage;
  }
}
