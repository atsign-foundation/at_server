import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class PolResponseHandler extends BaseResponseHandler {
  @override
  String getResponseMessage(String verbResult, String prompt) {
    var responseMessage;
    if (verbResult != null && verbResult.startsWith('pol:')) {
      responseMessage = '${verbResult.split(':')[1]}';
    }
    return responseMessage;
  }

  @override
  bool isComplete() {
    return true;
  }
}
