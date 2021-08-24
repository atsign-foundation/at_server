import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The “lookup” verb allows the lookup of a particular key in the @sign's secondary server. The “lookup” verb provides public lookups and specific key look ups when authenticated as a particular @sign.
/// If a lookup is valid the resulting information is returned with the data: <value of the key>
/// A malformed request closes the @sign client connection.
/// Lookup command is polymorphic in nature and can be executed with or without authentication.
/// Syntax: lookup:<key to lookup>
/// e.g.
/// without auth - lookup:phone@alice - returns public value of alice's phone
/// with auth - @alice@lookup:phone@bob - returns value of phone shared by @bob with @alice.
class Lookup extends Verb {
  @override
  String name() => 'lookup';

  @override
  String syntax() => VerbSyntax.lookup;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g lookup:location@bob';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
