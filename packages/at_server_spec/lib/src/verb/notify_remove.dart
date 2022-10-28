import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The “notify:remove” verb deletes the notification from Notification keystore.
/// The @sign should be authenticated using the cram/pkam verb prior to use the notify verb.
/// A malformed request does not close the @sign client connection.
///
/// Syntax: notify:remove:<id>
class NotifyRemove extends Verb {
  @override
  String name() => 'notify';

  @override
  String syntax() => VerbSyntax.notifyRemove;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g notify:remove:<notificationId>';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
