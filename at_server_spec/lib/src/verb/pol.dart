import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_server_spec/src/verb/from.dart';
import 'package:at_commons/at_commons.dart';

/// The "pol"(Proof of Life) verb is used to signal to the @alice secondary server to check for the cookie on the @bob secondary server.
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
