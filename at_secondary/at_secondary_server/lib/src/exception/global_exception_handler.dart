import 'dart:io';

import 'package:args/args.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// GlobalExceptionHandler class is used to handle all the exceptions in the system.
var logger = AtSignLogger('GlobalExceptionHandler');

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
    if (exception is InvalidAtSignException ||
        exception is UnAuthenticatedException ||
        exception is BufferOverFlowException ||
        exception is IllegalArgumentException ||
        exception is ConnectionInvalidException) {
      // All of these are SEVERE
      logger.severe(exception.toString());
      await _sendResponseForException(exception, atConnection);
      // TODO but do they necessarily need the connection to be closed?
      _closeConnection(atConnection);
    } else if (exception is BlockedConnectionException ||
        exception is InvalidSyntaxException ||
        exception is InvalidAtKeyException) {
      // This is normal behaviour, log as INFO
      logger.info(exception.toString());
      await _sendResponseForException(exception, atConnection);

      // We're closing the connection because
      //   BlockedConnectionException thrown when the "from" atsign is on the "do not allow" list
      //   InvalidSyntaxException is thrown because invalid syntax is rude, so we're rude in return
      _closeConnection(atConnection);
    } else if (exception is DataStoreException) {
      logger.severe(exception.toString());
      // TODO should we keep the connection open rather than closing it?
      await _sendResponseForException(exception, atConnection);
      _closeConnection(atConnection);
    } else if (exception is InboundConnectionLimitException) {
      // This is SEVERE and requires different handling so we use _handleInboundLimit
      logger.severe(exception.toString());
      await _handleInboundLimit(exception, clientSocket!);
    } else if (exception is OutboundConnectionLimitException ||
        exception is LookupException ||
        exception is SecondaryNotFoundException ||
        exception is HandShakeException ||
        exception is UnAuthorizedException ||
        exception is OutBoundConnectionInvalidException ||
        exception is KeyNotFoundException ||
        exception is AtConnectException ||
        exception is AtTimeoutException ||
        exception is InvalidAtSignException ||
        exception is UnAuthenticatedException) {
      // TODO Not sure some of these are really worthy of WARNINGS, but let's leave as is for now
      logger.warning(exception.toString());
      await _sendResponseForException(exception, atConnection);
    } else if (exception is ArgParserException) {
      // TODO [gkc] I suspect this code block is not reachable. Verify and delete
      logger.shout("Terminating secondary due to ${exception.toString()}");
      try {
        await AtSecondaryServerImpl.getInstance().stop();
      } finally {
        exit(1);
      }
    } else if (exception is InternalServerError) {
      logger.severe(exception.toString());
      await _handleInternalException(exception, atConnection);
    } else {
      logger.shout("Unexpected exception '${exception.toString()}'");
      await _handleInternalException(
          InternalServerException(exception.toString()), atConnection);
      _closeConnection(atConnection);
    }
  }

  Future<void> _handleInboundLimit(
      AtException exception, Socket clientSocket) async {
    var errorCode = getErrorCode(exception);
    var errorDescription = getErrorDescription(errorCode);
    clientSocket.write('error:$errorCode-$errorDescription\n');
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
    await _sendResponseForException(exception, atConnection);
  }

  /// Method to write response to client
  /// Params: AtException, AtConnection
  /// We'll get error code based on the exception and write error:<error_code> to the client socket
  Future<void> _sendResponseForException(
      Exception exception, AtConnection? atConnection) async {
    if (atConnection != null) {
      if (!atConnection.isInValid()) {
        var prompt = _getPrompt(atConnection);
        var errorCode = getErrorCode(exception);
        errorCode ??= 'AT0011';

        var errorDescription;
        if (exception is AtException) {
          errorDescription =
              '${getErrorDescription(errorCode)} : ${exception.message}';
        } else {
          errorDescription =
              '${getErrorDescription(errorCode)} : ${exception.toString()}';
        }
        _writeToSocket(atConnection, prompt, errorCode, errorDescription);
      }
    }
  }

  String _getPrompt(AtConnection atConnection) {
    var isAuthenticated = atConnection.getMetaData().isAuthenticated;
    var atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var prompt = isAuthenticated ? '$atSign@' : '@';
    return prompt;
  }

  String? getErrorCode(Exception exception) {
    return error_codes[exception.runtimeType.toString()];
  }

  String? getErrorDescription(String? errorCode) {
    return error_description[errorCode];
  }

  void _writeToSocket(AtConnection atConnection, String prompt,
      String? errorCode, String errorDescription) {
    atConnection.write('error:$errorCode-$errorDescription\n$prompt');
  }
}
