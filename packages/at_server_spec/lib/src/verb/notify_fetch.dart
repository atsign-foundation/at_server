import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The “notify:fetch” is used to get the notification using notificationId
/// A malformed request does not close the @sign client connection.
///
/// Syntax: notify:fetch:<notification-id>
class NotifyFetch extends Verb {
  @override
  String name() => 'notify';

  @override
  String syntax() => VerbSyntax.notifyFetch;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g notify:fetch:<notification-id>';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
