import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// Verb used for generating OTP for APKAM enrollments
class Otp extends Verb {
  @override
  String name() => 'otp';

  @override
  String syntax() => VerbSyntax.otp;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'otp:get[:ttl:<ms>], otp:put:<spp>[:ttl:<ms>], otp:list, '
        'or otp:delete:<otp>|spp';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
