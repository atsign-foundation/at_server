import 'package:at_server_spec/at_server_spec.dart';

class AtRootServerContext extends AtServerContext {
  int? port;
  int? httpsPort;
  bool? httpsEnabled;
  String? redisServerHost;
  int? redisServerPort;
  String? redisAuth;
  bool? useSSL;
  AtSecurityContext? securityContext;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AtRootServerContext &&
          runtimeType == other.runtimeType &&
          port == other.port &&
          httpsPort == other.httpsPort &&
          httpsEnabled == other.httpsEnabled &&
          redisServerHost == other.redisServerHost &&
          redisServerPort == other.redisServerPort &&
          redisAuth == other.redisAuth &&
          useSSL == other.useSSL &&
          securityContext == other.securityContext;

  @override
  int get hashCode => Object.hash(port, httpsPort, httpsEnabled,
      redisServerHost, redisServerPort, redisAuth, useSSL, securityContext);
}
