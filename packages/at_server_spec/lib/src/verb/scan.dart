import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "scan" verb scans the available keys for you at the public level. If the key has a '_' character has it first character, then it is omitted from the scan list, although it can still be looked up if known.
/// The scan verb when used by unauthenticated @sign user, scans for keys that are available to you at your current state.
/// The scan when used by an authenticated user, scans all the available keys on the secondary server.
///
/// Syntax: scan
/// To get the keys matches with the regex - scan:<regex>
/// To scan the commit log instead of the keystore - scan:cl (authenticated
/// connections only). Returns a JSON array, ascending by commitId, of
/// {"atKey", "operation", "commitId", "opTime"}: operation is the commit
/// operation symbol (+ # * -), opTime an ISO 8601 UTC timestamp. DELETE
/// entries are included, so a client can find entries for keys that no
/// longer exist and remove them with delete:nc. The same regex, hidden-key
/// and enrollment-namespace filters as a keystore scan apply.
class Scan extends Verb {
  @override
  String name() => 'scan';

  @override
  String syntax() => VerbSyntax.scan;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'scan';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
