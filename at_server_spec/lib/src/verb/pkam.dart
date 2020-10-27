import 'package:at_server_spec/src/verb/from.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The pkam( Public Key Authentication Mechanism) verb is used to authenticate the @sign to the secondary server. This is similar to how ssh authentication works. On successful request, binds the @sign to the secondary server.
/// On successful pkam verb request, the @sign is successfully authenticated to the secondary server and allows user to Add/Update, Delete and lookup the keys in their respective secondary servers.
///
///Syntax: pkam:<signature>
class Pkam extends Verb {
  @override
  String name() => 'pkam';

  @override
  String syntax() => VerbSyntax.pkam;

  @override
  Verb dependsOn() {
    return From();
  }

  @override
  String usage() {
    return 'pkam:<signature>';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
