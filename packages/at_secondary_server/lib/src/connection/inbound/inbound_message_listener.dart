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

  /// True while [_drain] is dispatching. Append signals arriving during a
  /// dispatch are dropped: the running loop re-reads the buffer after every
  /// command, so it takes whatever they appended. Without this, a second
  /// invocation of the buffer listener would take commands from the same
  /// buffer while the first is still awaiting a handler, dispatching them
  /// out of order.
  bool _draining = false;

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
          if (_draining) return;
          _draining = true;
          try {
            await _drain();
          } finally {
            _draining = false;
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

  /// Dispatches every complete command the buffer holds, in arrival order,
  /// awaiting each one's handler before taking the next.
  ///
  /// What arrives on the connection is a byte stream, not a command: a client
  /// that writes a second command without waiting for the first one's
  /// response puts both in the buffer, and everything past the first
  /// terminator belongs to the next command rather than to this one.
  Future<void> _drain() async {
    while (true) {
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
      final commandBytes = _buffer.takeCommand();
      if (commandBytes == null) {
        return;
      }
      final command = utf8.decode(commandBytes).trim();
      if (logger.logger.isLoggable(Level.INFO)) {
        logger.info(logger.getAtConnectionLogMessage(connection.metaData,
            'RCVD: ${BaseSocketConnection.truncateForLogging(command)}'));
      }
      // if command is '@exit', close the connection.
      if (command == '@exit') {
        await _finishedHandler();
        return;
      }
      await onBufferEndCallBack(command, connection);
      // NOTE A handler may have closed the connection - a revoked
      // enrollment, an invalid stream id. Anything queued behind it must not
      // be dispatched onto it.
      if (connection.metaData.isClosed || connection.metaData.isStale) {
        _buffer.clear();
        return;
      }
    }
  }

  /// Handles messages on the inbound client's connection and adds them to _buffer's stream.
  /// Closes the inbound connection in case of any error.
  Future<void> _messageHandler(streamData) async {
    connection.metaData.lastAccessed = DateTime.timestamp();
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

/// A [at_commons.ByteBuffer] that signals its reader on every append and
/// hands out one terminator-delimited command at a time.
class StreamableByteBuffer extends at_commons.ByteBuffer {
  /// Shared sentinel for the append signal — the stream listener discards
  /// the payload (it reads the buffer itself), so we don't need to copy
  /// the bytes per chunk.
  static final Uint8List _appendSignal = Uint8List(0);

  final StreamController<Uint8List> _controller = StreamController<Uint8List>();
  Stream<Uint8List> get stream => _controller.stream;

  /// Whether the command at the head of the buffer has already been through
  /// [InboundCommandValidator.validate].
  bool validated = false;

  /// Offset of the terminator that ends the command at the head of the
  /// buffer, or -1 while the buffer holds no complete command.
  int _terminatorAt = -1;

  StreamableByteBuffer({super.capacity});

  int get _terminator => terminatingChar as int;

  /// True when the buffer holds at least one complete command.
  bool get hasCommand => _terminatorAt >= 0;

  @override
  void append(dynamic data) {
    List<int> bytes = data as List<int>;
    if (_terminatorAt < 0) {
      final offset = bytes.indexOf(_terminator);
      if (offset >= 0) {
        _terminatorAt = length() + offset;
      }
    }
    super.append(bytes);
    _controller.add(_appendSignal);
  }

  /// Removes the command at the head of the buffer and returns its bytes
  /// without the terminator, leaving whatever followed the terminator
  /// buffered as the start of the next command. Null when the buffer holds
  /// no complete command.
  List<int>? takeCommand() {
    if (_terminatorAt < 0) return null;
    final buffered = getData();
    final command = buffered.sublist(0, _terminatorAt);
    final remainder = buffered.sublist(_terminatorAt + 1);
    clear();
    if (remainder.isNotEmpty) {
      _terminatorAt = remainder.indexOf(_terminator);
      super.append(remainder);
    }
    return command;
  }

  @override
  void clear() {
    validated = false;
    _terminatorAt = -1;
    super.clear();
  }

  /// Runs [InboundCommandValidator.validate] over the command at the head of
  /// the buffer, at most once per command.
  void validate(AtConnection connection) {
    if (validated) return;
    final len = length();
    if (len == 0) return;
    // Defer validation until we have either a complete command or enough
    // bytes (see [InboundCommandValidator.minBytesForValidation]) to fully
    // cover the longest possible verb+subcommand. Validating against a
    // shorter partial buffer would reject the first fragment of a fragmented
    // command (e.g. `'loo'` arriving before `'kup:publickey@alice\n'`) and
    // bin the buffer, dropping the command bytes still in flight.
    if (!hasCommand && len < InboundCommandValidator.minBytesForValidation) {
      return;
    }
    final buffered = getData();
    InboundCommandValidator.validate(
        hasCommand ? buffered.sublist(0, _terminatorAt) : buffered, connection);
    validated = true;
  }
}
