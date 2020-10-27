import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class DefaultResponseHandler extends BaseResponseHandler {
  @override
  String getResponseMessage(String verbResult, String promptKey) {
    var responseMessage;
    if (verbResult != null && verbResult.startsWith('data:')) {
      responseMessage = '${verbResult}\n' + promptKey;
    } else {
      responseMessage = 'data:${verbResult}\n' + promptKey;
    }
    return responseMessage;
  }
}
