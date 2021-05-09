import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "llookup" verb can be used to locally lookup keys stored on the secondary server. To perform local look up, the user should be successfully authenticated via the "cram" verb.
/// malformed request closes the @sign client connection.
///
/// Syntax: llookup:<key to lookup>
class LocalLookup extends Verb {
  @override
  String name() => 'llookup';

  @override
  String syntax() => VerbSyntax.llookup;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g llookup:location@bob';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
