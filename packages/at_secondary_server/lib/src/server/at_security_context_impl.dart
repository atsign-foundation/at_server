import 'package:at_secondary/src/server/at_secondary_config.dart';

class AtSecurityContextImpl {
  static final AtSecurityContextImpl _singleton =
      AtSecurityContextImpl._internal();

  factory AtSecurityContextImpl() {
    return _singleton;
  }

  AtSecurityContextImpl._internal();

  /// Returns path of the public key of the server cert presented to clients.
  String get publicKeyPath => AtSecondaryConfig.certificateChainLocation;

  /// Returns path of the private key of the server cert.
  String get privateKeyPath => AtSecondaryConfig.privateKeyLocation;

  /// Returns path of the public key of the client cert which we will present
  /// to other atServers when we connect to them.
  String get publicKeyPathMtls =>
      AtSecondaryConfig.certificateChainLocationMtls;

  /// Returns path of the private key of the client cert.
  String get privateKeyPathMtls => AtSecondaryConfig.privateKeyLocationMtls;

  /// Returns path of trusted root certificates file.
  String get trustedCertificatePath =>
      AtSecondaryConfig.trustedCertificateLocation;
}
