import 'dart:io';
import 'package:at_root_server/src/server/at_root_config.dart';
import 'package:at_server_spec/at_server_spec.dart';

class AtSecurityContextImpl implements AtSecurityContext {
  static final Map<String, String> envVars = Platform.environment;
  final String? _certChainPath = AtRootConfig.certificateChainLocation;
  final String? _privateKeyPath = AtRootConfig.privateKeyLocation;

  @override
  String privateKeyPath() {
    return _privateKeyPath!;
  }

  @override
  String publicKeyPath() {
    return _certChainPath!;
  }

  @override
  String bundle() {
    // TODO: implement bundle
    throw Exception('Not implemented');
  }

  @override
  String trustedCertificatePath() {
    // TODO: implement trustedCertificatePath
    throw Exception('Not implemented');
  }
}
