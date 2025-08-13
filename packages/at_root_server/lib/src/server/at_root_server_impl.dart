import 'dart:async';
import 'dart:io';
import 'package:at_root_server/src/client/at_root_client.dart';
import 'package:at_root_server/src/client/at_root_client_pool.dart';
import 'package:at_root_server/src/server/at_root_config.dart';
import 'package:at_root_server/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_persistence_root_server/at_persistence_root_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_commons/at_commons.dart';

/// Impl class for the root server of the @protocol.
/// This Contains methods to start, stop and serve the requests.
class RootServerImpl implements AtRootServer {
  final logger = AtSignLogger('RootServerImpl');
  static late dynamic _serverSocket;
  static HttpServer? httpServer;
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
      var client = RootClient(socket);
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
      if (httpServer != null) {
        await httpServer!.close();
      }
      var result = RootClientPool().closeAll();
      if (result) {
        //close server socket
        await _serverSocket.close();
        _isRunning = false;
      }
    } on Exception {
      throw Exception;
    }
  }

  Future<void> _startHttpsServer() async {
    var secCon = SecurityContext.defaultContext;

    secCon.useCertificateChain(serverContext.securityContext!.publicKeyPath());
    secCon.usePrivateKey(serverContext.securityContext!.privateKeyPath());

    httpServer = await HttpServer.bindSecure(
        InternetAddress.anyIPv4, serverContext.httpsPort!, secCon);

    logger.info('HttpsServer listening at ${serverContext.httpsPort}');

    final keyStoreManager = KeystoreManagerImpl();
    httpServer!.listen((HttpRequest request) async {
      try {
        switch (request.method) {
          case 'GET':
            String requestPath = Uri.decodeComponent(request.requestedUri.path);
            if (requestPath.startsWith('/')) {
              requestPath = requestPath.substring(1);
            }
            if (requestPath.startsWith('@')) {
              requestPath = requestPath.substring(1);
            }
            List<String> pathParts = requestPath.split('/');
            String atSign = pathParts[0];
            String? onwardLookup;
            if (pathParts.length >= 2) {
              onwardLookup = pathParts[1];
            }
            logger.info('GET ${request.requestedUri.path} ($requestPath)');
            String? v = await keyStoreManager.getKeyStore().get(atSign);

            if (v == null) {
              request.response.statusCode = HttpStatus.notFound;
              request.response.write('null');
            } else {
              if (onwardLookup == null) {
                request.response.statusCode = HttpStatus.ok;
                request.response.write(v);
              } else {
                request.response.statusCode = HttpStatus.movedTemporarily;
                request.response.headers.add(
                    HttpHeaders.locationHeader, 'https://$v/$onwardLookup');
              }
            }
          default:
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.write('Unauthorized');
        }
      } catch (e) {
        logger.info('Error while handling http req'
            ' ${Uri.decodeFull(request.requestedUri.toString())}'
            ' : $e');
      } finally {
        await request.response.close();
      }
    });
  }

  void _startSecuredServer() {
    try {
      var secCon = SecurityContext.defaultContext;
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
    serverSocket.listen((connection) {
      _handle(AtClientConnectionImpl(connection));
    }, onError: (error) {
      if (error is HandshakeException) {
        // This is not unusual.
        // See https://github.com/atsign-foundation/at_server/issues/1590
        return;
      } else {
        logger.warning('ServerSocket.listen: onError :$error');
      }
    });
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
