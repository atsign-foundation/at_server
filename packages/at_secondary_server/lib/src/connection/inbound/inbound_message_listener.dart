import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_commons/at_commons.dart' as at_commons;
import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart' show Level;

///Listener class for messages received by [InboundConnection]
/// For each incoming message [DefaultVerbExecutor()] execute is invoked
class InboundMessageListener {
  InboundConnection connection;
  var logger = AtSignLogger('InboundListener');
  final _buffer = StreamableByteBuffer(capacity: 10240000);

  InboundMessageListener(this.connection);

  late Function(String, InboundConnection) onBufferEndCallBack;
  late Function(List<int>, InboundConnection) onStreamCallBack;

  /// Listens to the underlying connection's socket
  void listen(callback, streamCallBack) {
    onStreamCallBack = streamCallBack;
    onBufferEndCallBack = callback;
    logger.finest(
        'Calling inbound underlying.listen within runZonedGuarded block');
    runZonedGuarded(() {
      //setup underlying connection
      connection.underlying.listen(_messageHandler,
          onDone: _finishedHandler, onError: _errorHandler);
      _buffer.stream.listen(
        (Uint8List _) async {
          try {
            _buffer.validate(connection);
          } on Exception catch (e) {
            logger.warning(logger.getAtConnectionLogMessage(
              connection.metaData,
              e.toString(),
            ));
            await GlobalExceptionHandler.getInstance()
                .handle(e, atConnection: connection);
            _buffer.clear();
            return;
          }
          if (_buffer.isEnd()) {
            var command = utf8.decode(_buffer.getData());
            command = command.trim();
            if (logger.logger.isLoggable(Level.INFO)) {
              logger.info(logger.getAtConnectionLogMessage(connection.metaData,
                  'RCVD: ${BaseSocketConnection.truncateForLogging(command)}'));
            }
            // if command is '@exit', close the connection.
            if (command == '@exit') {
              await _finishedHandler();
              return;
            }
            _buffer.clear();
            await onBufferEndCallBack(command, connection);
          }
        },
        onError: (e, st) {
          _buffer.clear();
          logger
              .severe('exception when handling message: $e - stack trace: $st');
        },
      );
      connection.metaData.isListening = true;
    }, (Object error, StackTrace st) {
      logger.warning(
          'runZonedGuarded received error $error - calling _errorHandler to close connection');
      _errorHandler(error, st);
    });
  }

  /// Handles messages on the inbound client's connection and adds them to _buffer's stream.
  /// Closes the inbound connection in case of any error.
  Future<void> _messageHandler(streamData) async {
    connection.metaData.lastAccessed = DateTime.now().toUtc();
    if (logger.isLoggable('finest')) {
      logger.finest('_messageHandler received ${streamData.runtimeType}'
          ' : $streamData ');
    }
    List<int> data;
    if (streamData is List<int>) {
      data = streamData;
    } else if (streamData is String) {
      data = utf8.encode(streamData);
    } else {
      logger.severe('Un-handled data type: ${streamData.runtimeType}');
      await _finishedHandler();
      return;
    }
    //ignore the data read if the connection is stale or closed
    if (connection.metaData.isStale || connection.metaData.isClosed) {
      //clear buffer as data is redundant
      _buffer.clear();
      return;
    }
    if (connection.metaData.isStream) {
      await onStreamCallBack(data, connection);
      return;
    }
    // If buffer has capacity add data to buffer,
    // Else raise bufferOverFlowException and close the connection.
    if (!_buffer.isOverFlow(data)) {
      _buffer.append(data);
    } else {
      _buffer.clear();
      await GlobalExceptionHandler.getInstance().handle(
          BufferOverFlowException('InboundBuffer overflow: server received'
              ' request which exceeded the buffer size limit.'
              ' Terminating the connection.'),
          atConnection: connection);
    }
  }

  /// Logs the error and closes the [InboundConnection]
  Future<void> _errorHandler(error, StackTrace st) async {
    logger.severe(error.toString());
    await _closeConnection();
  }

  /// Closes the [InboundConnection]
  Future<void> _finishedHandler() async {
    logger.info('_finishedHandler called - closing connection');
    await _closeConnection();
  }

  Future<void> _closeConnection() async {
    await connection.close();
    // Removes the connection from the InboundConnectionPool.
    AtSecondaryServerImpl.getInstance()
        .inboundConnectionManager
        .pool
        .remove(connection);
  }
}

class StreamableByteBuffer extends at_commons.ByteBuffer {
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();
  Stream<Uint8List> get stream => _controller.stream;
  bool validated = false;

  StreamableByteBuffer({super.capacity});

  @override
  void append(dynamic data) {
    List<int> bytes = data as List<int>;
    _controller.add(Uint8List.fromList(bytes));
    super.append(bytes);
  }

  @override
  void clear() {
    validated = false;
    super.clear();
  }

  void validate(AtConnection connection) {
    if (validated) return;
    InboundCommandValidator.validate(getData(), connection);
    validated = true;
  }
}
