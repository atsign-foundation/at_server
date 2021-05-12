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
  static final _defaultHandler = DefaultResponseHandler();
  static final _polHandler = PolResponseHandler();
  static final _fromHandler = FromResponseHandler();
  static final _statsHandler = StatsResponseHandler();
  static final _monitorHandler = MonitorResponseHandler();
  static final _streamHandler = StreamResponseHandler();
  static final _notifyAllHandler = NotifyAllResponseHandler();
  //static final _syncHandler = SyncResponseHandler();

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
