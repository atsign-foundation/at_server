import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_utils/at_logger.dart';

///Listener class for messages received by [OutboundClient]
class OutboundMessageListener {
  OutboundClient outboundClient;
  var logger = AtSignLogger('OutboundMessageListener');
  final _buffer = ByteBuffer(capacity: 10240000);
  late Queue _queue;

  OutboundMessageListener(this.outboundClient);

  /// Listens to the underlying connection's socket if the connection is created.
  /// @throws [AtConnectException] if the connection is not yet created
  void listen() async {
    outboundClient.outboundConnection?.getSocket().listen(_messageHandler,
        onDone: _finishedHandler, onError: _errorHandler);
    _queue = Queue();
    outboundClient.outboundConnection?.getMetaData().isListening = true;
  }

  /// Handles responses from the remote secondary, adds to [_queue] for processing in [read] method
  /// Throws a [BufferOverFlowException] if buffer is unable to hold incoming data
  Future<void> _messageHandler(data) async {
    //ignore the data if connection is closed or stale
    if (outboundClient.outboundConnection!.getMetaData().isStale || outboundClient.outboundConnection!.getMetaData().isClosed){
      _buffer.clear();
      return ;
    }
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
      logger.info('RCVD: [${outboundClient.outboundConnection!.metaData.sessionID}] ${BaseConnection.truncateForLogging(result)}');
      _queue.add(result);
    }
  }

  /// Reads the response sent by remote socket from the queue.
  /// Note: Exceptions thrown here, if not handled anywhere else, will be handled in [AtSecondaryServerImpl._executeVerbCallBack].
  /// Throws [AtConnectException] upon an 'error:...' response from the remote secondary.
  /// Throws [AtConnectException] upon a bad response (not 'data:...', not 'error:...') from remote secondary.
  /// Throws [TimeoutException] If there is no message in queue after [maxWaitMilliSeconds].
  Future<String?> read({int maxWaitMilliSeconds = 3000}) async {
    // ignore: prefer_typing_uninitialized_variables
    var result;

    //wait maxWaitMilliSeconds seconds for response from remote socket
    var loopCount = (maxWaitMilliSeconds / 50).round();

    for (var i = 0; i < loopCount; i++) {
      await Future.delayed(Duration(milliseconds: 50));
      var queueLength = _queue.length;
      if (queueLength > 0) {
        result = _queue.removeFirst();
        // result from another secondary should be either data: or error: or a @<atSign>@ denoting handshake completion
        if (result.startsWith('data:') ||
            (result.startsWith('@') && result.endsWith('@'))) {
          return result;
        } else if (result.startsWith('error:')) {
          // Right now, all callers of this method only expect there ever to be a 'data:' response.
          // So right now, the right thing to do here is to throw an exception.
          // We can leave the connection open since an 'error:' response indicates normal functioning on the other end
          try {
            result = result.toString().replaceFirst('error:', '');
            var errorMap = jsonDecode(result);
            throw AtExceptionUtils.get(
                errorMap['errorCode'], errorMap['errorDescription']);
          } on FormatException {
            // Catching the FormatException to preserve backward compatibility - responses without jsonEncoding.
            // TODO: Can remove the catch block in the next release (once all the existing servers are migrated to new version).
            throw AtConnectException(
                "Request to remote secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort} received error response '$result'");
          }
        } else {
          // any other response is unexpected and bad, so close the connection and throw an exception
          _closeOutboundClient();
          throw AtConnectException(
              "Unexpected response '$result' from remote secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort}");
        }
      }
    }
    // No response ... that's probably bad, so in addition to throwing an exception, let's also close the connection
    _closeOutboundClient();
    throw AtTimeoutException(
        "No response after $maxWaitMilliSeconds millis from remote secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort}");
  }

  /// Logs the error and closes the [OutboundClient]
  void _errorHandler(error) async {
    logger.severe(error.toString());
    await _closeOutboundClient();
  }

  /// Closes the [OutboundClient]
  void _finishedHandler() async {
    await _closeOutboundClient();
  }

  Future<void> _closeOutboundClient() async {
    // Changed the code here to no longer check if the client is invalid or not, since the outbound client can be
    // invalid if the *inbound* connection has become invalid, which can happen if the inbound client has closed
    // its socket immediately after making a request; this would in turn lead to the outbound client here not being
    // closed, which can't be right.
    // if (!outboundClient.isInValid()) {
    //   outboundClient.close();
    // }
    //
    // So, instead, we're just going to call close() on the outboundClient
    outboundClient.close();
  }
}