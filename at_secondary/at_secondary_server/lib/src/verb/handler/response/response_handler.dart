import 'package:at_server_spec/src/verb/response.dart';
import 'package:at_server_spec/at_server_spec.dart';

abstract class ResponseHandler {
  /// Process a given response and write the result to the connection
  /// @param [AtConnection]
  /// @param [Response]
  void process(AtConnection connection, Response response);
}
