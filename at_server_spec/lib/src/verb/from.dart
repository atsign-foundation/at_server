import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The “from” verb is used to tell the secondary server what @sign you claim to be, and the secondary server will respond with a challenge.
/// The challenge will be in the form of a full @ address and a cookie to place at that address. Before giving the challenge it will verify the client SSL certificate. 
/// The client SSL certificate has to match the FQDN list in the root server for that @sign in either the CN or SAN fields in the certificate
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
