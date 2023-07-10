import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';
import 'package:meta/meta.dart';

/// Verb used for generating OTP for APKAM enrollments
@experimental
class Totp extends Verb {
  @override
  String name() => 'totp';

  @override
  String syntax() => VerbSyntax.totp;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'totp:get or totp:validate:<otp>';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
