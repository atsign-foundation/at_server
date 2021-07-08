import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/at_server_spec.dart';

abstract class ResponseHandler {
  /// Process a given response and write the result to the connection
  /// @param [AtConnection]
  /// @param [Response]
  Future<void> process(AtConnection connection, Response response);
}
