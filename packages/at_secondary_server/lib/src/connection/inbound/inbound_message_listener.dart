import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_commons/at_commons.dart' as at_commons;
import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

///Listener class for messages received by [InboundConnection]
/// For each incoming message [DefaultVerbExecutor()] execute is invoked
class InboundMessageListener {
  InboundConnection connection;
  var logger = AtSignLogger('InboundListener');
  final _buffer = at_commons.ByteBuffer(capacity: 10240000);

  InboundMessageListener(this.connection);

  late Function(String, InboundConnection) onBufferEndCallBack;
  late Function(List<int>, InboundConnection) onStreamCallBack;

  /// Listens to the underlying connection's socket
  void listen(callback, streamCallBack) {
    onStreamCallBack = streamCallBack;
    onBufferEndCallBack = callback;
    connection.getSocket().listen(_messageHandler,
        onDone: _finishedHandler, onError: _errorHandler);
    connection
        .getSocket()
        .done
        .onError((error, stackTrace) => (_errorHandler(error)));
    connection.getMetaData().isListening = true;
  }

  /// Handles messages on the inbound client's connection and calls the verb executor
  /// Closes the inbound connection in case of any error.
  Future<void> _messageHandler(data) async {
    //ignore the data read if the connection is stale or closed
    if (connection.getMetaData().isStale || connection.getMetaData().isClosed) {
      //clear buffer as data is redundant
      _buffer.clear();
      return;
    }
    // If connection is invalid, throws ConnectionInvalidException and closes the connection
    if (connection.isInValid()) {
      _buffer.clear();
      logger.info('Inbound connection is invalid. Closing the connection');
      await GlobalExceptionHandler.getInstance().handle(
          ConnectionInvalidException('Connection is invalid'),
          atConnection: connection);
      return;
    }
    if (connection.getMetaData().isStream) {
      await onStreamCallBack(data, connection);
      return;
    }
    var bufferOverflow = false;
    // If buffer has capacity add data to buffer,
    // Else raise bufferOverFlowException and close the connection.
    if (!_buffer.isOverFlow(data)) {
      _buffer.append(data);
    } else {
      _buffer.clear();
      await GlobalExceptionHandler.getInstance().handle(
          BufferOverFlowException('buffer overflow'),
          atConnection: connection);
      bufferOverflow = true;
    }
    try {
      if (!bufferOverflow && _buffer.isEnd()) {
        //decode only when end of buffer is reached
        var command = utf8.decode(_buffer.getData());
        command = command.trim();
        logger.info(
            'RCVD: [${connection.getMetaData().sessionID}] ${BaseConnection.truncateForLogging(command)}');
        // if command is '@exit', close the connection.
        if (command == '@exit') {
          await _finishedHandler();
          return;
        }
        _buffer.clear();
        await onBufferEndCallBack(command, connection);
      }
    } on Exception catch (e) {
      _buffer.clear();
      logger.severe('exception in message handler:${e.toString()}');
    }
  }

  /// Logs the error and closes the [InboundConnection]
  Future<void> _errorHandler(error) async {
    logger.severe(error.toString());
    await _closeConnection();
  }

  /// Closes the [InboundConnection]
  Future<void> _finishedHandler() async {
    await _closeConnection();
  }

  Future<void> _closeConnection() async {
    if (!connection.isInValid()) {
      await connection.close();
    }
    // Removes the connection from the InboundConnectionPool.
    InboundConnectionPool.getInstance().remove(connection);
  }
}
