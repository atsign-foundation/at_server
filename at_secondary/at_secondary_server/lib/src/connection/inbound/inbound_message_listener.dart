import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_commons/at_commons.dart' as at_commons;
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

///Listener class for messages received by [InboundConnection]
/// For each incoming message [DefaultVerbExecutor()] execute is invoked
class InboundMessageListener {
  InboundConnection connection;
  var isStream;
  var logger = AtSignLogger('InboundListener');
  final _buffer = at_commons.ByteBuffer(capacity: 10240000);

  InboundMessageListener(this.connection);

  Function(String, InboundConnection) onBufferEndCallBack;
  Function(List<int>, InboundConnection) onStreamCallBack;

  /// Listens to the underlying connection's socket
  void listen(callback, streamCallBack) {
    onStreamCallBack = streamCallBack;
    onBufferEndCallBack = callback;
    connection.getSocket().listen(_messageHandler,
        onDone: _finishedHandler, onError: _errorHandler);
    connection.getMetaData().isListening = true;
  }

  /// Handles messages on the inbound client's connection and calls the verb executor
  /// Closes the inbound connection in case of any error.
  Future<void> _messageHandler(data) async {
    if (connection.getMetaData().isStream) {
      await onStreamCallBack(data, connection);
      return;
    }
    var bufferOverflow = false;
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
        logger.finer(
            'command received: $command sessionID:${connection.getMetaData().sessionID}');
        if (command == '@exit') {
          _finishedHandler();
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
  void _errorHandler(error) async {
    logger.severe(error.toString());
    await _closeConnection();
  }

  /// Closes the [InboundConnection]
  void _finishedHandler() async {
    await _closeConnection();
  }

  void _closeConnection() async {
    try {
      if (!connection.isInValid()) {
        await connection.close();
      }
    } on Exception catch (e) {
      logger.finer(
          'Exception while listening on inbound connection: ${e.toString()}');
    }
  }
}
