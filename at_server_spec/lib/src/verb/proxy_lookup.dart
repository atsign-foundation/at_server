import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "plookup" verb, provides a proxied public lookups for a resolver that perhaps is behind a firewall. This will allow a resolver to contact a @ server and have the @ server lookup both public @ handles information.
/// This will be useful in large enterprise environments where they would want all lookups going through a single secondary server for the entity or where a single port needs to be opened through a firewall to lookup @ handles.
/// The @sign should be authenticated using cram verb prior to use the plookup verb.
/// A malformed request closes the @sign client connection.
///
/// Syntax : plookup:<key to lookup>
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
