import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The “notify:list” allows the notify user.
/// The @sign should be authenticated using the cram/pkam verb prior to use the notify verb.
/// A malformed request does not close the @sign client connection.
///
/// Syntax: notify:ttl:<time> <to Atsign>:<key to notify>@<sender AtSign>
class NotifyStatus extends Verb {
  @override
  String name() => 'notify';

  @override
  String syntax() => VerbSyntax.notifyStatus;

  Verb dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g notify:status:<notification-id>';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
