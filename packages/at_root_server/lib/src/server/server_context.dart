import 'package:at_server_spec/at_server_spec.dart';

class AtRootServerContext extends AtServerContext {
  int? port = 6464;
  String? redisServerHost;
  int? redisServerPort;
  String? redisAuth;
  AtSecurityContext? securityContext;
}
