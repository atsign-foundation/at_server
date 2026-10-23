import 'dart:async';
import 'dart:io';

import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart' show PseudoServerSocket;
import 'package:meta/meta.dart';

/// The atServer's HTTP side: an [HttpServer] answering the connections
/// handed to it, holding at most [maxConnections] of them at once.
class HttpConnections {
  /// How long an HTTP connection with no request in progress is held. The
  /// HttpServer checks every [idleTimeout], so such a connection is closed
  /// within twice it.
  static const Duration idleTimeout = Duration(seconds: 5);

  static final AtSignLogger logger = AtSignLogger('HttpConnections');

  final PseudoServerSocket _sockets;
  final HttpServer _server;

  /// The most HTTP connections held at once; 0 or less holds none.
  final int maxConnections;

  bool _refusing = false;

  HttpConnections._(this._sockets, this._server, this.maxConnections);

  /// Starts an [HttpServer] on the connections [add] hands over from
  /// [serverSocket], answering each request with [onRequest]. An error the
  /// HttpServer raises is logged, never thrown.
  factory HttpConnections.serve(SecureServerSocket serverSocket,
      {required int maxConnections,
      required void Function(HttpRequest request) onRequest}) {
    final PseudoServerSocket sockets = PseudoServerSocket(serverSocket);
    late final HttpServer server;
    runZonedGuarded(() {
      server = HttpServer.listenOn(sockets)..idleTimeout = idleTimeout;
      server.listen(onRequest);
    }, (Object error, StackTrace stackTrace) {
      logger.warning('The HTTP server raised $error\n$stackTrace');
    });
    return HttpConnections._(sockets, server, maxConnections);
  }

  /// Hands [socket] to the HTTP server, or destroys it unanswered when
  /// [maxConnections] connections are already held.
  void add(Socket socket) {
    // NOTE no await between the count and the hand-over: the HttpServer
    // counts a connection as it is handed over.
    if (_server.connectionsInfo().total >= maxConnections) {
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
  }

  /// Closes the HTTP server and every connection it holds.
  @visibleForTesting
  Future<void> close() => _server.close(force: true);
}
