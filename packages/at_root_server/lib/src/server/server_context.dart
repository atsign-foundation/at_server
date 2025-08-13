import 'package:at_server_spec/at_server_spec.dart';

class AtRootServerContext extends AtServerContext {
  int? port;
  int? httpsPort;
  bool? httpsEnabled;
  String? redisServerHost;
  int? redisServerPort;
  String? redisAuth;
  AtSecurityContext? securityContext;
}
