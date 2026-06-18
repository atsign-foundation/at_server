import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/verb/handler/response/default_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/from_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/monitor_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/notify_all_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/pol_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/stats_response_handler.dart';
import 'package:at_secondary/src/verb/handler/response/stream_response_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';

abstract class ResponseHandlerManager {
  /// Returns the response handler for a given verb
  /// @param [Verb]
  /// @returns [ResponseHandler]
  ResponseHandler getResponseHandler(Verb verb);
}

class DefaultResponseHandlerManager implements ResponseHandlerManager {
  final Atsign currentAtSign;
  final GlobalExceptionHandler exceptionHandler;

  DefaultResponseHandlerManager(this.currentAtSign, this.exceptionHandler);

  late final _defaultHandler =
      DefaultResponseHandler(currentAtSign, exceptionHandler);
  late final _polHandler = PolResponseHandler(currentAtSign, exceptionHandler);
  late final _fromHandler =
      FromResponseHandler(currentAtSign, exceptionHandler);
  late final _statsHandler =
      StatsResponseHandler(currentAtSign, exceptionHandler);
  late final _monitorHandler =
      MonitorResponseHandler(currentAtSign, exceptionHandler);
  late final _streamHandler =
      StreamResponseHandler(currentAtSign, exceptionHandler);
  late final _notifyAllHandler =
      NotifyAllResponseHandler(currentAtSign, exceptionHandler);

  @override
  ResponseHandler getResponseHandler(Verb verb) {
    if (verb is Pol) {
      return _polHandler;
    } else if (verb is From) {
      return _fromHandler;
    } else if (verb is Stats) {
      return _statsHandler;
    } else if (verb is Monitor) {
      return _monitorHandler;
    } else if (verb is StreamVerb) {
      return _streamHandler;
    } else if (verb is NotifyAll) {
      return _notifyAllHandler;
    }
    return _defaultHandler;
  }
}
