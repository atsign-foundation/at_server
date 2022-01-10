import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The “notify:status” is used to get the notification status using notificationId
/// The notification status can be either delivered, errored, queued or expired.
/// The @sign should be authenticated using the cram/pkam verb prior to use the notify:status verb.
/// A malformed request does not close the @sign client connection.
///
/// Syntax: notify:status:<notification-id>
class NotifyStatus extends Verb {
  @override
  String name() => 'notify';

  @override
  String syntax() => VerbSyntax.notifyStatus;

  @override
  Verb? dependsOn() {
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
