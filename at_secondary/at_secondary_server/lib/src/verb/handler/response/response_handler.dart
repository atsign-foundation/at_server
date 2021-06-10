import 'package:at_commons/at_commons.dart';

abstract class ResponseHandler {
  /// Process a given response and write the result to the connection
  /// @param [AtConnection]
  /// @param [Response]
  Future<void> process(AtConnection connection, Response response);
}
