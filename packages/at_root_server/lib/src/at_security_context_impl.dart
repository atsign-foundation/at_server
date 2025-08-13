import 'dart:io';
import 'package:at_root_server/src/server/at_root_config.dart';
import 'package:at_server_spec/at_server_spec.dart';

class AtRootSecurityContextImpl implements AtSecurityContext {
  static final Map<String, String> envVars = Platform.environment;
  final String _certChainPath = AtRootConfig.certificateChainLocation;
  final String _privateKeyPath = AtRootConfig.privateKeyLocation;

  @override
  String privateKeyPath() {
    return _privateKeyPath;
  }

  @override
  String publicKeyPath() {
    return _certChainPath;
  }

  @override
  String bundle() {
    throw UnimplementedError();
  }

  @override
  String trustedCertificatePath() {
    throw UnimplementedError();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AtRootSecurityContextImpl &&
          runtimeType == other.runtimeType &&
          _certChainPath == other._certChainPath &&
          _privateKeyPath == other._privateKeyPath;

  @override
  int get hashCode => Object.hash(_certChainPath, _privateKeyPath);
}
