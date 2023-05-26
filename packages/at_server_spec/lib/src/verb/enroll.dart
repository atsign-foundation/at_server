import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// #TODO documentation
class Enroll extends Verb {
  @override
  String name() => 'enroll';

  @override
  String syntax() => VerbSyntax.enroll;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'enroll:request:appName:wavi:deviceName:iPhone:apkamPublicKey:<public_key>';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
