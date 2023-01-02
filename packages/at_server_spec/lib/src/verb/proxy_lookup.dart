import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "plookup" verb, provides a proxied public lookups for a resolver that perhaps is behind a firewall. This will allow a resolver to contact a @ server and have the @ server lookup both public @sign's information.
/// This will be useful in large enterprise environments where they would want all lookups going through a single secondary server for the entity or where a single port needs to be opened through a firewall to lookup @signs.
/// The @sign should be authenticated prior to using the plookup verb.
/// A malformed request closes the @sign client connection.
///
/// Syntax : plookup:<key to lookup>
/// e.g @bob:plookup:phone@alice - returns public value of alice's phone
/// Example: plookup:all:country@alice - returns all the details including key, value including the metadata
/// plookup:meta:country@alice - returns only metadata of the key
class ProxyLookup extends Verb {
  @override
  String name() => 'plookup';

  @override
  String syntax() => VerbSyntax.plookup;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g plookup:location@bob';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
