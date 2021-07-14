import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

///Listener class for messages received by [OutboundClient]
class OutboundMessageListener {
  OutboundClient client;
  var logger = AtSignLogger('OutboundMessageListener');
  final _buffer = ByteBuffer(capacity: 10240000);
  late Queue _queue;

  OutboundMessageListener(this.client);

  /// Listens to the underlying connection's socket if the connection is created.
  /// @throws [AtConnectException] if the connection is not yet created
  void listen() {
    var connection = client.outboundConnection;
    connection!.getSocket().listen(_messageHandler,
        onDone: _finishedHandler, onError: _errorHandler);
    _queue = Queue();
    connection.getMetaData().isListening = true;
  }

  /// Handles messages on the inbound client's connection and calls the verb executor
  /// Closes the inbound connection in case of any error.
  /// Throw a [BufferOverFlowException] if buffer is unable to hold incoming data
  Future<void> _messageHandler(data) async {
    String result;
    if (!_buffer.isOverFlow(data)) {
      // skip @ prompt. byte code for @ is 64
      if (data.length == 1 && data.first == 64) {
        return;
      }
      //ignore prompt(@ or @<atSign>@) after '\n'. byte code for \n is 10
      if (data.last == 64 && data.contains(10)) {
        data = data.sublist(0, data.lastIndexOf(10) + 1);
        _buffer.append(data);
      } else if (data.length > 1 && data.first == 64 && data.last == 64) {
        // pol responses do not end with '\n'. Add \n for buffer completion
        _buffer.append(data);
        _buffer.addByte(10);
      } else {
        _buffer.append(data);
      }
    } else {
      _buffer.clear();
      throw BufferOverFlowException('Buffer overflow on outbound connection');
    }
    if (_buffer.isEnd()) {
      result = utf8.decode(_buffer.getData());
      result = result.trim();
      _buffer.clear();
      _queue.addFirst(result);
    }
  }

  /// Reads the response sent by remote socket from the queue.
  /// If there is no message in queue after [maxWaitMilliSeconds], return null
  Future<String?> read({int maxWaitMilliSeconds = 5000}) async {
    var result;
    //wait maxWaitMilliSeconds seconds for response from remote socket
    var loopCount = (maxWaitMilliSeconds / 50).round();
    for (var i = 0; i < loopCount; i++) {
      await Future.delayed(Duration(milliseconds: 50));
      var queueLength = _queue.length;
      if (queueLength > 0) {
        result = _queue.removeFirst();
        // result from another secondary is either data or a @<atSign>@ denoting complete
        // of the handshake
        if (result.startsWith('data:') ||
            (result.startsWith('@') && result.endsWith('@'))) {
          return result;
        } else {
          //log any other response and ignore
          result = '';
        }
      }
    }
    return result;
  }

  /// Logs the error and closes the [OutboundClient]
  void _errorHandler(error) async {
    logger.severe(error.toString());
    await _closeClient();
  }

  /// Closes the [InboundConnection]
  void _finishedHandler() async {
    await _closeClient();
  }

  Future<void> _closeClient() async {
    if (!client.isInValid()) {
      client.close();
    }
  }
}
