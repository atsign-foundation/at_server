import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_server_spec/src/verb/from.dart';
import 'package:at_commons/at_commons.dart';

/// The "pol" verb allows to switch as another @sign user. To switch as another user, use from:<@sign>(The another @sign user) verb which gives a response as proof:<key>; then use pol verb. On successful authentication, the prompt changes to the another @sign user.
/// An invalid syntax closes the atsign client connection.
///
/// Syntax: pol
class Pol extends Verb {
  @override
  String name() => 'pol';

  @override
  String syntax() => VerbSyntax.pol;

  @override
  Verb dependsOn() {
    return From();
  }

  @override
  String usage() {
    return 'syntax pol e.g pol';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
