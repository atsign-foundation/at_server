import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
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

  /// How long since the peer last sent bytes this listener KEPT.
  ///
  /// A [Stopwatch] rather than wall-clock timestamps: [DateTime.now] can step
  /// backwards (an NTP correction), which would make an elapsed-time check
  /// negative and leave [read] spinning while it holds the client's
  /// request/response mutex.
  ///
  /// [read] bounds a response two ways: a total budget for the whole
  /// exchange, and this, the gap it will tolerate between one chunk and the
  /// next. A large response arriving steadily is not the same thing as a
  /// peer that has stopped answering, and a single total budget cannot tell
  /// them apart — it either cuts off a response that was still coming, or
  /// waits out the full budget on a peer that is never going to reply.
  final Stopwatch _sinceLastReceived = Stopwatch()..start();

  /// The connection this listener was created for.
  ///
  /// Held rather than read back from [outboundClient] each time, because a
  /// client can replace both its connection and its listener
  /// ([OutboundClient] does exactly that when a peer closes the socket rather
  /// than answering a verb it does not understand). The listener left behind
  /// stays subscribed to the socket it was made for, and when that socket
  /// finally ends it must tear down THAT connection -- not whichever one has
  /// since taken its place.
  final OutboundSocketConnection? _connection;

  OutboundMessageListener(this.outboundClient)
      : _connection = outboundClient.outboundConnection;

  /// Listens to the underlying connection's socket if the connection is created.
  /// @throws [AtConnectException] if the connection is not yet created
  void listen() async {
    logger.finest(
        'Calling outbound underlying.listen within runZonedGuarded block');

    runZonedGuarded(() {
      _connection?.underlying.listen(messageHandler,
          onDone: _finishedHandler, onError: _errorHandler);
      _connection?.metaData.isListening = true;
    }, (Object error, StackTrace st) {
      logger.warning(
          'runZonedGuarded received error $error - calling _errorHandler to close connection');
      _errorHandler(error, st);
    });
  }

  static const int _atChar = 64;
  static const int _newLine = 10;

  /// The last byte appended to [_buffer], or -1 when the buffer is empty.
  ///
  /// Tracked rather than read back from the buffer because
  /// `ByteBuffer.getData()` copies the whole buffer, and the framing below
  /// asks "was the previous byte a newline?" once per candidate boundary.
  int _lastByte = -1;

  /// Discards anything held for an exchange that is over, and starts the
  /// inter-chunk clock for a new one.
  ///
  /// [OutboundClient] calls this immediately before writing a request, under
  /// its request/response mutex, so nothing is in flight. An outbound client
  /// only ever sends strict request/response verbs and the peer never pushes,
  /// so a queued message or a partial one at that moment belongs to an
  /// exchange that has already been answered or abandoned. Left in place it
  /// would answer THIS request instead -- a well-formed record for a key
  /// nobody asked for.
  void beginExchange() {
    // The prompt that closed the previous response is left in the buffer on
    // purpose -- it is stripped from the front of whatever comes next -- so
    // finding one here is the normal case and says nothing. Report only what
    // a caller should not have left behind.
    if (_queue.isNotEmpty || !_residueIsOnlyAPrompt()) {
      logger.warning('Discarding ${_queue.length} unread message(s) and'
          ' ${_buffer.length()} buffered bytes from ${outboundClient.toAtSign}'
          ' left over from a previous exchange');
    }
    _queue.clear();
    _clearBuffer();
    _sinceLastReceived.reset();
  }

  /// The messages framed so far and not yet read.
  ///
  /// Exists so a test can compare this framing against the one this package
  /// shipped previously, message for message, without going through [read]
  /// (which throws on an `error:` response and so cannot report a queue).
  @visibleForTesting
  List<String> get queuedForTest => _queue.cast<String>().toList();

  /// Whether the buffer holds nothing but a prompt (`@` or `@<atSign>@`),
  /// which is what a completed exchange legitimately leaves behind.
  bool _residueIsOnlyAPrompt() {
    var length = _buffer.length();
    if (length == 0) {
      return true;
    }
    // An atSign is bounded well below this; anything longer is a response.
    if (length > 64) {
      return false;
    }
    var bytes = _buffer.getData();
    return bytes.first == _atChar &&
        bytes.last == _atChar &&
        !bytes.contains(_newLine);
  }

  void _clearBuffer() {
    _buffer.clear();
    _lastByte = -1;
  }

  void _appendRange(List<int> data, int start, int end) {
    if (end <= start) {
      return;
    }
    _buffer.append(data.sublist(start, end));
    _lastByte = data[end - 1];
  }

  /// Takes the message the buffer now holds, and queues it.
  ///
  /// The terminating newline is removed; a prompt carried over from the
  /// previous response is stripped from the front.
  void _flushMessage() {
    if (_buffer.length() == 0) {
      return;
    }
    var bytes = _buffer.getData().toList();
    if (bytes.isNotEmpty && bytes.last == _newLine) {
      bytes.removeLast();
    }
    _clearBuffer();
    String result;
    try {
      result = utf8.decode(bytes);
    } on FormatException catch (e) {
      // Malformed bytes are not a reason to take the connection down from
      // inside a socket callback, and they must not stay in the buffer to
      // corrupt every response after them.
      logger.warning('Discarding a malformed message from'
          ' ${outboundClient.toAtSign}: $e');
      return;
    }
    result = _stripPrompt(result.trim());
    if (result.isEmpty) {
      logger.finer('Ignoring an empty message from ${outboundClient.toAtSign}');
      return;
    }
    if (logger.logger.isLoggable(Level.INFO)) {
      logger.info(logger.getAtConnectionLogMessage(
          _connection!.metaData,
          'RCVD: ${BaseSocketConnection.truncateForLogging(result)}'));
    }
    _queue.add(result);
  }

  /// Removes a prompt the peer wrote ahead of this response.
  ///
  /// A prompt has no terminator of its own, so it is carried into the next
  /// message rather than framed separately: `@alice@data:x` is the response
  /// `data:x` behind the prompt that closed the previous one.
  String _stripPrompt(String result) {
    var colonIndex = result.indexOf(':');
    if (colonIndex < 0) {
      return result;
    }
    var prefix = result.substring(0, colonIndex);
    if (!prefix.contains('@')) {
      return result;
    }
    return '${prefix.substring(prefix.lastIndexOf('@') + 1)}'
        '${result.substring(colonIndex)}';
  }

  /// Handles responses from the remote secondary, adds to [_queue] for
  /// processing in the [read] method.
  ///
  /// Messages are framed by scanning for a newline followed by the `@` that
  /// begins the peer's prompt, walking the accumulated buffer rather than
  /// inspecting the last byte of whichever chunk happened to arrive. The
  /// distinction matters: a response and its prompt are written by the peer
  /// as one string but delivered in however many pieces the network chooses,
  /// so any rule keyed on a chunk boundary loses or corrupts bytes when the
  /// split lands somewhere awkward.
  ///
  /// Throws a [BufferOverFlowException] if the buffer cannot hold the data.
  @visibleForTesting
  Future<void> messageHandler(data) async {
    //ignore the data if connection is closed or stale
    if (_connection == null ||
        _connection!.metaData.isStale ||
        _connection!.metaData.isClosed) {
      _clearBuffer();
      return;
    }
    // A zero-length read carries nothing. Indexing it would throw out of a
    // socket callback, which runZonedGuarded turns into a closed connection.
    if (data.isEmpty) {
      return;
    }
    if (_buffer.isOverFlow(data)) {
      _clearBuffer();
      throw BufferOverFlowException('OutboundBuffer overflow: server sent'
          ' request which was longer than the maximum of bytes.'
          ' Terminating the connection.');
    }
    // The bare prompt the peer writes on connect, and again when it is not
    // authenticated. It only means "send me a request" -- but only when
    // nothing is part-assembled, or it is a payload byte that happens to be
    // an atSign.
    if (data.length == 1 && data.first == _atChar && _buffer.length() == 0) {
      // Deliberately does NOT reset the inter-chunk clock: the byte is
      // discarded, and discarded bytes are not a response still arriving. A
      // peer emitting nothing but prompts must still look quiet.
      return;
    }

    var segmentStart = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] != _atChar) {
        continue;
      }
      // The byte before this one: from this chunk if there is one, otherwise
      // whatever the buffer already ends with.
      var previous = i > 0 ? data[i - 1] : _lastByte;
      if (previous != _newLine) {
        continue;
      }
      // A newline followed by the start of a prompt ends a message.
      _appendRange(data, segmentStart, i);
      _flushMessage();
      // The prompt itself starts the next buffer, and _stripPrompt takes it
      // off the front of whatever response follows it.
      segmentStart = i;
    }
    _appendRange(data, segmentStart, data.length);
    _sinceLastReceived.reset();

    // `pol` is the one response with no terminator of any kind: a bare
    // `@<atSign>@`. Nothing in the byte stream marks its end, so it is framed
    // only while the client says it is waiting for one.
    if (expectingHandshakePrompt &&
        _lastByte == _atChar &&
        _buffer.length() >= 2) {
      var bytes = _buffer.getData();
      if (bytes.first == _atChar) {
        _flushMessage();
      }
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
    final sinceStart = Stopwatch()..start();
    _sinceLastReceived.reset();

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
          _clearBuffer();
          _throwAtExceptionFromErrorResponse(result);
        } else {
          // any other response is unexpected and bad, so close the connection and throw an exception
          _clearBuffer();
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
      if (_connection == null ||
          _connection!.metaData.isClosed ||
          _connection!.metaData.isStale) {
        // A peer that answers and then hangs up has still answered. Take the
        // message before reporting the close over the top of it.
        if (_flushIfTerminated()) {
          continue;
        }
        _clearBuffer();
        _closeOutboundClient();
        throw AtConnectException(
            'Connection to remote secondary ${outboundClient.toAtSign}'
            ' at ${outboundClient.toHost}:${outboundClient.toPort}'
            ' was closed before a response was received');
      }
      // The whole exchange has run out of time.
      if (sinceStart.elapsedMilliseconds > maxWaitMilliSeconds) {
        _clearBuffer();
        _closeOutboundClient();
        throw AtTimeoutException(
            "No response after $maxWaitMilliSeconds millis from remote secondary ${outboundClient.toAtSign} at ${outboundClient.toHost}:${outboundClient.toPort}");
      }
      // Nothing has arrived for a while. A response that is still coming
      // keeps resetting this, so reaching it means the peer has gone quiet
      // rather than that the response is merely large.
      if (_sinceLastReceived.elapsedMilliseconds > transientWaitTimeMillis) {
        _clearBuffer();
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

  /// Frames a response the peer terminated with a newline but never followed
  /// with a prompt, which is what it writes when it is about to hang up (see
  /// the connection-limit path in GlobalExceptionHandler).
  ///
  /// Called from [read] once the connection is known to be gone: nothing more
  /// can arrive, so the newline is the end of the message. Doing it here
  /// rather than in the socket's done handler keeps it on the path that has a
  /// caller waiting for the answer.
  ///
  /// Returns true if a message was queued.
  bool _flushIfTerminated() {
    if (_buffer.length() == 0 || _lastByte != _newLine) {
      return false;
    }
    var before = _queue.length;
    _flushMessage();
    return _queue.length > before;
  }

  /// Closes the [OutboundClient]
  void _finishedHandler() async {
    logger.info('_finishedHandler called - closing connection');
    _closeOutboundClient();
  }

  _closeOutboundClient() {
    // A listener outlives its connection when the client reconnects, and it
    // stays subscribed to the socket it was made for. When that socket
    // finally ends, closing through the client would tear down whichever
    // connection the client holds NOW -- a live one this listener has nothing
    // to do with. Close only our own and leave the rest alone.
    if (!identical(_connection, outboundClient.outboundConnection)) {
      logger.info('The socket for a replaced connection to'
          ' ${outboundClient.toAtSign} ended; closing that connection and'
          ' leaving the current one alone');
      _connection?.close();
      return;
    }
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
