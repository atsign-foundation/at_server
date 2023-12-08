import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';
import 'package:meta/meta.dart';

/// Verb used for generating OTP for APKAM enrollments
@experimental
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
    return 'otp:get or otp:validate:<otp>';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
