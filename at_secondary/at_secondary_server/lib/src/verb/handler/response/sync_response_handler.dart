import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class SyncResponseHandler extends BaseResponseHandler {
  // @override
  // String getResponseMessage(String verbResult, String promptKey) {
  //   var responseMessage;
  //   if (verbResult != null) {
  //     responseMessage =
  //         '${verbResult.length}#${verbResult}\$'; //\n'; + promptKey;
  //   }
  //   return responseMessage;
  // }

  @override
  String getResponseMessage(String verbResult, String prompt) {
    return '';
  }
}
