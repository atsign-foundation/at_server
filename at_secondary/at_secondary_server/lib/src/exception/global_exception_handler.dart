import 'dart:io';

import 'package:args/args.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// GlobalExceptionHandler class is used to handle all the exceptions in the system.
class GlobalExceptionHandler {
  static final GlobalExceptionHandler _singleton =
      GlobalExceptionHandler._internal();

  GlobalExceptionHandler._internal();

  factory GlobalExceptionHandler.getInstance() {
    return _singleton;
  }

  /// handle method will perform required action based on the exception
  /// params: AtException, AtConnection
  Future<void> handle(Exception exception,
      {AtConnection? atConnection, Socket? clientSocket}) async {
    if (exception is InvalidSyntaxException ||
        exception is InvalidAtSignException ||
        exception is BlockedConnectionException ||
        exception is UnAuthenticatedException ||
        exception is BufferOverFlowException ||
        exception is IllegalArgumentException) {
      // If we get InvalidSyntaxException, InvalidAtSignException, InboundConnectionLimitException
      // send error code
      // Close all the related inbound/outbound connections
      await _sendResponse(exception as AtException, atConnection);
      _closeConnection(atConnection);
    } else if (exception is DataStoreException ||
        exception is ConnectionInvalidException) {
      // In case of DataStoreException
      // Retry for n number of times and Close connection.
      _closeConnection(atConnection);
    } else if (exception is InboundConnectionLimitException) {
      await _handleInboundLimit(exception, clientSocket!);
    } else if (exception is OutboundConnectionLimitException ||
        exception is LookupException ||
        exception is SecondaryNotFoundException ||
        exception is HandShakeException ||
        exception is UnAuthorizedException ||
        exception is OutBoundConnectionInvalidException) {
      // In case of OutboundConnectionLimitException, LookupException, ConnectionInvalidException
      // SecondaryNotFoundException, HandShakeException, UnAuthorizedException, UnverifiedConnectionException
      // send error code.
      await _sendResponse(exception as AtException, atConnection);
    } else if (exception is AtServerException ||
        exception is ArgParserException) {
      // In case of AtServerException terminate the server
      _terminateSecondary();
    } else if (exception is InternalServerError) {
      await _handleInternalException(exception, atConnection);
    } else {
      await _handleInternalException(
          InternalServerException(exception.toString()), atConnection);
      _closeConnection(atConnection);
    }
  }

  Future<void> _handleInboundLimit(
      AtException exception, Socket clientSocket) async {
    var error_code = getErrorCode(exception);
    var error_description = getErrorDescription(error_code);
    clientSocket.write('error:$error_code-$error_description\n');
    await clientSocket.close();
  }

  /// Method to close connection.
  /// params: AtConnection
  /// This will close the connection and remove it from pool
  void _closeConnection(AtConnection? atConnection) async {
    await atConnection?.close();
  }

  Future<void> _handleInternalException(
      AtException exception, AtConnection? atConnection) async {
    await _sendResponse(exception, atConnection);
  }

  /// Method to write response to client
  /// Params: AtException, AtConnection
  /// We'll get error code based on the exception and write error:<error_code> to the client socket
  Future<void> _sendResponse(
      AtException exception, AtConnection? atConnection) async {
    if (atConnection != null) {
      if (!atConnection.isInValid()) {
        var prompt = _getPrompt(atConnection);
        var error_code = getErrorCode(exception);
        var error_description =
            '${getErrorDescription(error_code)} : ${exception.message}';
        _writeToSocket(atConnection, prompt, error_code, error_description);
      }
    }
  }

  void _terminateSecondary() {
    exit(0);
  }

  String _getPrompt(AtConnection atConnection) {
    var isAuthenticated = atConnection.getMetaData().isAuthenticated;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var prompt = isAuthenticated ? '$atSign@' : '@';
    return prompt;
  }

  String? getErrorCode(Exception exception) {
    var error_code = error_codes[exception.runtimeType.toString()];
    return error_code;
  }

  String? getErrorDescription(String? error_code) {
    return error_description[error_code];
  }

  void _writeToSocket(AtConnection atConnection, String prompt,
      String? error_code, String error_description) {
    atConnection.write('error:$error_code-$error_description\n$prompt');
  }
}
