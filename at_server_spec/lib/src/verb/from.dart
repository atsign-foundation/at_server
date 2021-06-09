import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "from" verb is used to establish a new @sign connection to an @sign secondary server.
/// It tells the @server what @sign you claim to be and the @server on successful connection gives a challenge for authentication of @sign
///
/// Syntax: from:<@sign>
class From extends Verb {
  @override
  String name() => 'from';

  @override
  String syntax() => VerbSyntax.from;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'syntax from:@<atSign> \n e.g from:@alice';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
