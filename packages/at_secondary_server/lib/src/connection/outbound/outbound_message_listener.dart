import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart' show Level;
import 'package:meta/meta.dart';

///Listener class for messages received by [OutboundClient]
class OutboundMessageListener {
  static final RegExp _errorPrefix = RegExp('^error:');

  OutboundClient outboundClient;
  var logger = AtSignLogger('OutboundMessageListener');
  final _buffer = ByteBuffer(capacity: 10240000);
  final Queue _queue = Queue();

  /// Whether a bare `@<atSign>@` arriving on the wire is a response in its
  /// own right, rather than the prompt trailing a response already queued.
  ///
  /// `pol` is the only response carrying no `data:` prefix and no
  /// terminating newline, so it is the only one shaped like a bare prompt.
  /// The two are indistinguishable from the bytes alone — both arrive on an
  /// empty buffer immediately after a flush — so [OutboundClient] sets this
  /// around its `pol` exchange and nowhere else.
  bool expectingHandshakePrompt = false;

  /// When the peer was last heard from, on this connection.
  ///
  /// [read] bounds a response two ways: a total budget for the whole
  /// exchange, and this, the gap it will tolerate between one chunk and the
  /// next. A large response arriving steadily is not the same thing as a
  /// peer that has stopped answering, and a single total budget cannot tell
  /// them apart — it either cuts off a response that was still coming, or
  /// waits out the full budget on a peer that is never going to reply.
  DateTime _lastReceivedTime = DateTime.now();

  OutboundMessageListener(this.outboundClient);

  /// Listens to the underlying connection's socket if the connection is created.
  /// @throws [AtConnectException] if the connection is not yet created
  void listen() async {
    logger.finest(
        'Calling outbound underlying.listen within runZonedGuarded block');

    runZonedGuarded(() {
      outboundClient.outboundConnection?.underlying.listen(messageHandler,
          onDone: _finishedHandler, onError: _errorHandler);
      outboundClient.outboundConnection?.metaData.isListening = true;
    }, (Object error, StackTrace st) {
      logger.warning(
          'runZonedGuarded received error $error - calling _errorHandler to close connection');
      _errorHandler(error, st);
    });
  }

  /// Handles responses from the remote secondary, adds to [_queue] for processing in [read] method
  /// Throws a [BufferOverFlowException] if buffer is unable to hold incoming data
  @visibleForTesting
  Future<void> messageHandler(data) async {
    //ignore the data if connection is closed or stale
    if (outboundClient.outboundConnection!.metaData.isStale ||
        outboundClient.outboundConnection!.metaData.isClosed) {
      _buffer.clear();
      return;
    }
    // The peer is alive and sending, whether or not this chunk completes a
    // response. [read]'s inter-chunk budget is measured from here.
    _lastReceivedTime = DateTime.now();
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
      } else if (data.length > 1 &&
          data.first == 64 &&
          data.last == 64 &&
          _buffer.length() == 0) {
        // A bare `@<atSign>@` on an empty buffer is either the pol response
        // or the prompt trailing a response that has already been queued,
        // segmented away from it by the network. Only the caller knows which,
        // and it says so via [expectingHandshakePrompt].
        if (!expectingHandshakePrompt) {
          // The trailing prompt. It carries no payload and no caller is
          // waiting for it, so queueing it would answer the NEXT request
          // with it and leave every later response one behind.
          logger.finer('Discarding the prompt that trailed a response already'
              ' read from ${outboundClient.toAtSign}');
          return;
        }
        // pol responses do not end with '\n'. Add \n for buffer completion
        _buffer.append(data);
        _buffer.addByte(10);
      } else {
        // Everything else is response payload — including a mid-response
        // chunk that happens to begin and end with '@', which the branch
        // above must not claim, or the response is silently truncated.
        _buffer.append(data);
      }
    } else {
      _buffer.clear();
      throw BufferOverFlowException('OutboundBuffer overflow: server sent'
          ' request which was longer than the maximum of bytes.'
          ' Terminating the connection.');
    }
    if (_buffer.isEnd()) {
      result = utf8.decode(_buffer.getData());
      result = result.trim();
      _buffer.clear();
      if (logger.logger.isLoggable(Level.INFO)) {
        logger.info(logger.getAtConnectionLogMessage(
            outboundClient.outboundConnection!.metaData,
            'RCVD: ${BaseSocketConnection.truncateForLogging(result)}'));
      }
      _queue.add(result);
    }
  }

  /// Reads the response sent by remote socket from the queue.
  /// Note: Exceptions thrown here, if not handled anywhere else, will be handled in [AtSecondaryServerImpl._executeVerbCallBack].
  /// Throws [AtConnectException] upon an 'error:...' response from the remote secondary.
  /// Throws [AtConnectException] upon a bad response (not 'data:...', not 'error:...') from remote secondary.
  /// Throws [AtTimeoutException] if the whole exchange exceeds
  /// [maxWaitMilliSeconds], or if nothing arrives from the peer for
  /// [transientWaitTimeMillis]. Both are needed: the first alone cannot tell
  /// a large response still arriving from a peer that has stopped answering.
  Future<String> read(
      {int maxWaitMilliSeconds = 30000,
      int transientWaitTimeMillis = 10000}) async {
    var loopMillis = 10;
    var startTime = DateTime.now();
    _lastReceivedTime = startTime;

    while (true) {
      var queueLength = _queue.length;
      if (queueLength > 0) {
        String result = _queue.removeFirst();
        // result from another secondary should be either data: or error: or,
        // when the pol exchange is in flight, a @<atSign>@ denoting handshake
        // completion. A bare prompt at any other time is not an answer to
        // anything, so it must not be handed back as one.
        if (result.startsWith('data:') ||
            (expectingHandshakePrompt &&
                result.startsWith('@') &&
                result.endsWith('@'))) {
          return result;
        } else if (result.startsWith('error:')) {
          // Right now, all callers of this method only expect there ever to be a 'data:' response.
          // So right now, the right thing to do here is to throw an exception.
          // We can leave the connection open since an 'error:' response indicates normal functioning on the other end
          result = result.replaceFirst(_errorPrefix, '');
          // A partial response left in the buffer belongs to an exchange that
          // is over. Discard it, or it prefixes the next response and the
          // caller after this one is answered with a corrupted record.
          _buffer.clear();
          _throwAtExceptionFromErrorResponse(result);
        } else {
          // any other response is unexpected and bad, so close the connection and throw an exception
          _buffer.clear();
          _closeOutboundClient();
          throw AtConnectException(
              "Unexpected response '$result' from remote secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort}");
        }
      }
      // Once the connection is closed no response can ever arrive —
      // messageHandler drops data received on a closed connection — so
      // don't wait out the timeout. This matters when a peer closes the
      // connection instead of replying with an error upon receiving a verb
      // it does not understand (atServers up to v3.0.28 do this).
      if (outboundClient.outboundConnection == null ||
          outboundClient.outboundConnection!.metaData.isClosed) {
        _buffer.clear();
        _closeOutboundClient();
        throw AtConnectException(
            'Connection to remote secondary ${outboundClient.toAtSign}'
            ' at ${outboundClient.toHost}:${outboundClient.toPort}'
            ' was closed before a response was received');
      }
      // The whole exchange has run out of time.
      if (DateTime.now().difference(startTime).inMilliseconds >
          maxWaitMilliSeconds) {
        _buffer.clear();
        _closeOutboundClient();
        throw AtTimeoutException(
            "No response after $maxWaitMilliSeconds millis from remote secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort}");
      }
      // Nothing has arrived for a while. A response that is still coming
      // keeps resetting this, so reaching it means the peer has gone quiet
      // rather than that the response is merely large.
      if (DateTime.now().difference(_lastReceivedTime).inMilliseconds >
          transientWaitTimeMillis) {
        _buffer.clear();
        _closeOutboundClient();
        throw AtTimeoutException(
            "Nothing received for $transientWaitTimeMillis millis from remote"
            " secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort}");
      }
      await Future.delayed(Duration(milliseconds: loopMillis));
    }
  }

  AtException _throwAtExceptionFromErrorResponse(String errorResponse) {
    try {
      var errorMap = jsonDecode(errorResponse);
      throw AtExceptionUtils.get(
          errorMap['errorCode'], errorMap['errorDescription']);
    } on FormatException {
      // Catching the FormatException to preserve backward compatibility - responses without jsonEncoding.
      // get error code and description from error response
      String? errorCode;
      try {
        errorCode = errorResponse.substring(
            errorResponse.indexOf('AT'), errorResponse.indexOf('-'));
        logger.finer('errorCode: $errorCode');
      } on Exception {
        logger.warning(
            'Unable to extract error code from errorResponse: $errorResponse');
        // if we are unable to get errorCode from error response, do nothing
      } on Error {
        logger.warning(
            'Unable to extract error code from errorResponse: $errorResponse');
        // if we are unable to get errorCode from error response, do nothing
      }
      if (errorCode != null && errorCode.isNotEmpty) {
        var errorDescription = errorResponse
            .substring(errorResponse.indexOf(errorCode) + errorCode.length + 1);
        throw AtExceptionUtils.get(errorCode, errorDescription);
      } else {
        throw AtConnectException(
            "Request to remote secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort} received error response '$errorResponse'");
      }
    }
  }

  /// Logs the error and closes the [OutboundClient]
  void _errorHandler(error, StackTrace st) async {
    logger.severe(error.toString());
    _closeOutboundClient();
  }

  /// Closes the [OutboundClient]
  void _finishedHandler() async {
    logger.info('_finishedHandler called - closing connection');
    _closeOutboundClient();
  }

  _closeOutboundClient() {
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
