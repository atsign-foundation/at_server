import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_server_spec/at_server_spec.dart';

class AtSecurityContextImpl implements AtSecurityContext {
  static final AtSecurityContextImpl _singleton =
      AtSecurityContextImpl._internal();
  final String _certChainPath = AtSecondaryConfig.certificateChainLocation;
  final String _privateKeyPath = AtSecondaryConfig.privateKeyLocation;
  final String _trustedCertificatePath =
      AtSecondaryConfig.trustedCertificateLocation;

  factory AtSecurityContextImpl() {
    return _singleton;
  }

  AtSecurityContextImpl._internal();

  @override
  String privateKeyPath() {
    return _privateKeyPath;
  }

  @override
  String publicKeyPath() {
    return _certChainPath;
  }

  @override
  String trustedCertificatePath() {
    return _trustedCertificatePath;
  }

  @override
  String bundle() {
    // TODO: implement bundle
    return null;
  }
}
