import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class DefaultResponseHandler extends BaseResponseHandler {
  DefaultResponseHandler(super.currentAtSign, super.exceptionHandler);

  @override
  String getResponseMessage(String? verbResult, String prompt) {
    String responseMessage;
    if (verbResult != null && verbResult.startsWith('data:')) {
      responseMessage = '$verbResult\n$prompt';
    } else {
      responseMessage = 'data:$verbResult\n$prompt';
    }
    return responseMessage;
  }
}
