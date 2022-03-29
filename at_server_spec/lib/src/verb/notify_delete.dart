import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The “notify:list” verb displays all the notifications received by the @sign .
/// The @sign should be authenticated using the cram/pkam verb prior to use the notify verb.
/// A malformed request does not close the @sign client connection.
///
/// Syntax: notify:list - list all the notifications
/// notify:list:<regex> - list notifications matched with the regex
/// To List notification between two dates and matches with the regex
/// notify:list:<StartDate>:<EndDate>:<regex>
/// regex, startDate, endDate are optional
class NotifyDelete extends Verb {
  @override
  String name() => 'notify';

  @override
  String syntax() => VerbSyntax.notifyDelete;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g notify:delete:<notificationId>';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
