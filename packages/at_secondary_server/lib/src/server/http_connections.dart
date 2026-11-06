import 'dart:async';
import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart' show PseudoServerSocket;
import 'package:meta/meta.dart';

/// The atServer's HTTP side: an [HttpServer] answering the connections
/// handed to it, holding at most [maxConnections] of them at once.
class HttpConnections {
  /// How long the atServer holds an HTTP connection with no request in
  /// progress. The HttpServer checks every idle timeout, so such a connection
  /// is closed within twice it.
  static const Duration defaultIdleTimeout = Duration(seconds: 5);

  /// How long the atServer allows an answer to be sent before it closes the
  /// connection.
  static const Duration defaultAnswerDeadline = Duration(seconds: 30);

  static final AtSignLogger logger = AtSignLogger('HttpConnections');

  final PseudoServerSocket _sockets;
  final HttpServer _server;

  /// The most HTTP connections held at once; 0 or less holds none.
  final int maxConnections;

  /// How long an answer may take to be sent before its connection is closed.
  final Duration answerDeadline;

  bool _refusing = false;

  HttpConnections._(
      this._sockets, this._server, this.maxConnections, this.answerDeadline);

  /// Starts an [HttpServer] on the connections [add] hands over from
  /// [serverSocket], answering each request with [onRequest]. A connection
  /// with no request in progress is closed within twice [idleTimeout], and
  /// one whose answer is not sent within [answerDeadline] is closed. An error
  /// on the HTTP side once it is listening is logged, never thrown.
  factory HttpConnections.serve(SecureServerSocket serverSocket,
      {required int maxConnections,
      required Duration idleTimeout,
      required Duration answerDeadline,
      required void Function(HttpRequest request) onRequest}) {
    final PseudoServerSocket sockets = PseudoServerSocket(serverSocket);
    final HttpServer server = HttpServer.listenOn(sockets)
      ..idleTimeout = idleTimeout;
    Zone.current.fork(specification: ZoneSpecification(handleUncaughtError:
        (Zone self, ZoneDelegate parent, Zone zone, Object error,
            StackTrace st) {
      logger.warning('An error on the HTTP side: $error\n$st');
    })).run(() => server.listen((HttpRequest request) {
          request.response.deadline = answerDeadline;
          onRequest(request);
        }));
    return HttpConnections._(sockets, server, maxConnections, answerDeadline);
  }

  /// How long a connection with no request in progress is held.
  Duration? get idleTimeout => _server.idleTimeout;

  /// The HTTP connections held now.
  @visibleForTesting
  int get held => _server.connectionsInfo().total;

  /// Hands [socket] to the HTTP server, or destroys it unanswered when
  /// [maxConnections] connections are already held or the server cannot
  /// take it.
  void add(Socket socket) {
    // NOTE no await between the count and the hand-over: the HttpServer
    // counts a connection as it is handed over.
    final int before = _server.connectionsInfo().total;
    if (before >= maxConnections) {
      if (_refusing) {
        logger.finer('Closed an HTTP connection beyond $maxConnections');
      } else {
        _refusing = true;
        logger.warning('Holding $maxConnections HTTP connections, the most'
            ' connection.http_max_limit allows; closing further ones until'
            ' one closes');
      }
      socket.destroy();
      return;
    }
    _refusing = false;
    _sockets.add(socket);
    if (_server.connectionsInfo().total == before) {
      socket.destroy();
    }
  }

  /// Closes the HTTP server, every connection it holds, and the socket it
  /// takes them from.
  Future<void> close() async {
    await _server.close(force: true);
    await _sockets.close();
  }
}
