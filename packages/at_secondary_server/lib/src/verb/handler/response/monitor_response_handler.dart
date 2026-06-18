import 'package:at_secondary/src/verb/handler/response/base_response_handler.dart';

class MonitorResponseHandler extends BaseResponseHandler {
  MonitorResponseHandler(super.currentAtSign, super.exceptionHandler);

  @override
  String getResponseMessage(String? verbResult, String prompt) {
    return '';
  }
}
