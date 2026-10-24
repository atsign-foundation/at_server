import 'dart:async';
import 'dart:io';
import 'package:at_root_server/src/client/at_root_client.dart';
import 'package:at_root_server/src/client/at_root_client_pool.dart';
import 'package:at_root_server/src/directory_lookup.dart';
import 'package:at_root_server/src/server/at_root_config.dart';
import 'package:at_root_server/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart' show PseudoServerSocket;
import 'package:meta/meta.dart';
import 'package:at_commons/at_commons.dart' hide StringBuffer;

/// Impl class for the root server of the @protocol.
/// This Contains methods to start, stop and serve the requests.
class RootServerImpl implements AtRootServer {
  final logger = AtSignLogger('RootServerImpl');
  static late dynamic _serverSocket;
  static HttpServer? httpServer;

  /// Serves the TLS port's connections that negotiate http/1.1.
  static HttpServer? alpnHttpServer;

  /// How long an HTTP connection may stay idle. HttpServer checks it on a
  /// timer of the same period, so an idle connection closes within twice it.
  static const Duration httpIdleTimeout = Duration(seconds: 5);

  /// The protocols the TLS port offers by ALPN.
  static const List<String> alpnProtocols = ['atProtocol/1.0', 'http/1.1'];

  /// Where both protocols read the atDirectory's records.
  @visibleForTesting
  DirectoryLookup lookup = redisDirectoryLookup;
  bool _isRunning = false;
  bool _stopInProgress = false;
  late AtRootServerContext serverContext;

  /// Returns status of the server
  /// return type - bool
  /// @return true is the server is running else returns false.
  @override
  bool isRunning() {
    logger.info('Server is already running');
    return _isRunning == true;
  }

  /// Method to start the root server.
  /// Return type - void
  /// Method will exit without throwing exception if server is already running
  @override
  void start() {
    if (serverContext.port == null) {
      throw AtServerException('server port is not set');
    }

    if (serverContext.redisServerHost == null) {
      throw AtServerException('redis host is not set');
    }

    if (serverContext.redisServerPort == null) {
      throw AtServerException('redis port is not set');
    }

    if (serverContext.redisAuth == null) {
      throw AtServerException('redis auth is not set');
    }

    if (_isRunning) {
      return;
    }
    try {
      _isRunning = true;
      RootClientPool().init();

      if (serverContext.useSSL!) {
        _startSecuredServer();
      } else {
        _startUnSecuredServer();
      }

      if (serverContext.httpsEnabled!) {
        _startHttpsServer();
      }
    } on Exception catch (exception) {
      _isRunning = false;
      throw AtServerException('rootServer().init error: $exception');
    }
  }

  /// This method serves an incoming request on a socket
  /// return type - void
  /// @param request - An instance of AtClientConnection that
  ///                  contains socket on which the connection has been made..
  /// AtClientConnection contains Instance of Client Socket
  void _handle(AtClientConnection request) {
    try {
      var socket = request.getSocket();
      // if stopInProgress is true - reject serve request
      if (_stopInProgress) {
        logger.severe("Stop in progress. Can't accept new requests.");
        socket.write("Stop in progress. Can't accept new requests.");
        socket.close();
        return;
      }
      logger.info('Connection from '
          '${socket.remoteAddress.address}:${socket.remotePort}');
      var client = RootClient(socket, lookup: lookup);
      logger.info('connection successful');
      client.write('@');
    } catch (e) {
      logger.warning('Error in _handle(request): $e');
    }
  }

  /// Method to Stop the server.
  /// return type - void
  /// All the client sockets will be closed and removed from RootClientPool
  /// Close server socket
  /// set _isRunning flag to false
  /// Close redis connection
  @override
  Future<void> stop() async {
    _stopInProgress = true;
    try {
      // NOTE the port stops accepting first, so no connection is accepted
      // after the server that would serve it has closed.
      await _serverSocket.close();
      if (httpServer != null) {
        await httpServer!.close();
        httpServer = null;
      }
      if (alpnHttpServer != null) {
        await alpnHttpServer!.close();
        alpnHttpServer = null;
      }
      RootClientPool().closeAll();
      _isRunning = false;
    } on Exception {
      throw Exception;
    }
  }

  Future<void> _startHttpsServer() async {
    // NOTE its own context, so the TLS port's ALPN offer is never made here.
    final SecurityContext secCon = SecurityContext()
      ..useCertificateChain(serverContext.securityContext!.publicKeyPath())
      ..usePrivateKey(serverContext.securityContext!.privateKeyPath());

    httpServer = await HttpServer.bindSecure(
        InternetAddress.anyIPv4, serverContext.httpsPort!, secCon)
      ..idleTimeout = httpIdleTimeout;

    logger.info('HttpsServer listening at ${serverContext.httpsPort}');

    httpServer!.listen(handleHttpRequest,
        onError: (Object e) =>
            logger.warning('A connection to the HTTPS port failed: $e'));
  }

  /// Answers one HTTP request from [lookup]'s records: the record for
  /// `GET /@<atSign>`, or a redirect to that atSign's atServer for a path
  /// below it, readable from any origin and ending its connection. Never
  /// throws: a request it cannot answer is answered 400 or 500.
  Future<void> handleHttpRequest(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
      response.persistentConnection = false;
      if (request.uri.toString().length > 1000) {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      switch (request.method) {
        case 'GET':
          String decodedRequestPath;
          try {
            decodedRequestPath = Uri.decodeComponent(request.uri.path);
          } on FormatException {
            response.statusCode = HttpStatus.badRequest;
            return;
          }
          logger.info('GET $decodedRequestPath');

          if (decodedRequestPath.startsWith('/')) {
            decodedRequestPath = decodedRequestPath.substring(1);
          }
          if (decodedRequestPath.startsWith('@')) {
            decodedRequestPath = decodedRequestPath.substring(1);
          }
          final List<String> pathParts = decodedRequestPath.split('/');
          final String? key = directoryKeyOf(pathParts.removeAt(0));
          final String? v = key == null ? null : await lookup(key);

          if (v == null) {
            response.statusCode = HttpStatus.notFound;
            response.write('404 not found');
          } else if (pathParts.every((String part) => part.isEmpty)) {
            response.statusCode = HttpStatus.ok;
            response.write(v);
          } else {
            final StringBuffer location = StringBuffer('https://$v/@')
              ..write(Uri.encodeComponent(key!))
              ..write('/')
              ..write(pathParts.map(Uri.encodeComponent).join('/'));
            if (request.uri.query.isNotEmpty) {
              location.write('?${request.uri.query}');
            }
            response.statusCode = HttpStatus.movedTemporarily;
            response.headers
                .add(HttpHeaders.locationHeader, location.toString());
          }
        default:
          response.statusCode = HttpStatus.unauthorized;
          response.write('Unauthorized');
      }
    } catch (e) {
      logger.warning('Could not answer an HTTP request for ${request.uri}: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
      } on StateError {
        // NOTE the status cannot change once the headers are sent.
      }
    } finally {
      try {
        await response.close();
      } catch (e) {
        logger.finer('An HTTP answer was not delivered: $e');
      }
    }
  }

  void _startSecuredServer() {
    try {
      // NOTE its own context, so the HTTPS port never makes this ALPN offer.
      final SecurityContext secCon = SecurityContext();
      var retryCount = 0;
      var certsAvailable = false;
      // if certs are unavailable then retry max 10 minutes
      while (true) {
        if (retryCount > 0) {
          sleep(Duration(seconds: 10));
        }
        try {
          if (certsAvailable || retryCount > 60) {
            break;
          }
          secCon.useCertificateChain(
              serverContext.securityContext!.publicKeyPath());
          secCon.usePrivateKey(serverContext.securityContext!.privateKeyPath());
          secCon.setAlpnProtocols(alpnProtocols, true);
          certsAvailable = true;
        } on FileSystemException {
          retryCount++;
          logger.info('certs unavailable. Retry count $retryCount');
        }
      }
      if (certsAvailable) {
        SecureServerSocket.bind(
                InternetAddress.anyIPv4, serverContext.port!, secCon)
            .then((SecureServerSocket socket) {
          logger.info(
              'root server started on version : ${AtRootConfig.rootServerVersion}');
          logger.info('SecureServerSocket listening at ${serverContext.port}');
          _serverSocket = socket;
          _listen(_serverSocket);
        });
      } else {
        logger.severe('certs not available');
      }
    } on Exception {
      rethrow;
    }
  }

  void _startUnSecuredServer() {
    try {
      ServerSocket.bind(InternetAddress.anyIPv4, serverContext.port!)
          .then((ServerSocket socket) {
        logger.info('Unsecure Socket open');
        _serverSocket = socket;
        _listen(_serverSocket);
      });
    } on Exception {
      rethrow;
    }
  }

  void _listen(var serverSocket) {
    final PseudoServerSocket? httpSockets =
        serverSocket is SecureServerSocket ? serveHttpOn(serverSocket) : null;
    serverSocket.listen((connection) => acceptSocket(connection, httpSockets),
        onError: (error) {
      if (error is HandshakeException) {
        // This is not unusual.
        // See https://github.com/atsign-foundation/at_server/issues/1590
        return;
      } else {
        logger.warning('ServerSocket.listen: onError :$error');
      }
    });
  }

  /// Starts [alpnHttpServer] on the connections [serverSocket] hands it, and
  /// returns the socket that hands them over. An error the HTTP server
  /// raises is logged, never thrown.
  @visibleForTesting
  PseudoServerSocket serveHttpOn(SecureServerSocket serverSocket) {
    final PseudoServerSocket httpSockets = PseudoServerSocket(serverSocket);
    runZonedGuarded(() {
      alpnHttpServer = HttpServer.listenOn(httpSockets)
        ..idleTimeout = httpIdleTimeout;
      alpnHttpServer!.listen(handleHttpRequest);
    },
        (Object e, StackTrace st) =>
            logger.warning('An HTTP connection failed: $e\n$st'));
    return httpSockets;
  }

  /// Serves [connection] the Atsign Protocol, or hands it to [httpSockets]
  /// when it negotiated http/1.1. An unexpected error closes only
  /// [connection].
  @visibleForTesting
  void acceptSocket(Socket connection, PseudoServerSocket? httpSockets) {
    try {
      if (httpSockets != null &&
          connection is SecureSocket &&
          connection.selectedProtocol == 'http/1.1') {
        httpSockets.add(connection);
        return;
      }
      _handle(AtClientConnectionImpl(connection));
    } catch (e, st) {
      logger.warning(
          'Closed a new connection after an unexpected error: $e\n$st');
      connection.destroy();
    }
  }

  @override
  void setServerContext(AtServerContext context) {
    serverContext = context as AtRootServerContext;
  }

  @override
  void pause() {
    //pause() is not supported by the at_root_server.
  }

  @override
  void resume() {
    //resume() is not supported by the at_root_server.
  }
}

/// Impl class of AtClientConnection
/// Contains method which Returns the socket on which the connection has been made.
class AtClientConnectionImpl implements AtClientConnection {
  AtClientConnectionImpl(this.socket);

  Socket socket;

  @override
  Socket getSocket() {
    return socket;
  }
}
