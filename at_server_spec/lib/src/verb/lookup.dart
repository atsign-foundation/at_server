import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The “lookup” verb allows the lookup of a particular address in the @ handles namespace. The “lookup” verb provides public lookups and specific key look ups when authenticated as a particular @ handle using the “from” and “pol” verbs.
/// If a lookup is valid the resulting information is returned with the data: header and a carriage return and a further @ prompt ready for further commands.
/// The @sign should be authenticated using the cram verb prior to use the lookup verb
/// Syntax: lookup:<key to lookup>
/// e.g.
/// without auth - lookup:phone@alice - returns public value of alice's phone
/// with auth - @alice@lookup:phone@bob - returns value of phone shared by @bob with @alice.
/// lookup:all:username@alice - returns all the details including metadata and value
/// lookup:meta:username@alice - returns only metadata of the key
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
