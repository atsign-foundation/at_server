import 'dart:io';

import 'package:at_server_spec/src/server/at_server.dart';

/// Represents the root server of the @protocol.
/// Contains methods to start, stop and server the requests.
abstract class AtRootServer implements AtServer {
  /// Sets the server context
  /// @param context - context for this server to start
  setServerContext(AtServerContext context);
}

/// Represent an incoming request
abstract class AtClientConnection {
  /// Returns the socket on which the connection has been made.
  Socket getSocket();
}

/// Represent the security context which is used by the server on start up.
abstract class AtSecurityContext {
  /// Returns path of the public key file.
  String publicKeyPath();

  /// Returns path of the private key file.
  String privateKeyPath();

  ///Returns path of trusted certificate file.
  String trustedCertificatePath();

  /// Returns path of the bundle.
  String bundle();
}
