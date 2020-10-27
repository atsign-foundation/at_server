import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The “notify” verb allows the notify user.
/// The @sign should be authenticated using the cram/pkam verb prior to use the notify verb.
/// A malformed request does not close the @sign client connection.
///
/// Syntax: notify:ttl:<time> <to Atsign>:<key to notify>@<sender AtSign>
class Notify extends Verb {
  @override
  String name() => 'notify';

  @override
  String syntax() => VerbSyntax.notify;

  @override
  Verb dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g notify:@colin:key@kevin';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
