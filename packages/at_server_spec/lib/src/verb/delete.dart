import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// Delete verb deletes a key from @sign's secondary server.
/// The @sign should be authenticated using the cram/pkam verb prior using the delete verb.
/// A malformed request closes the @sign client connection.
/// A delete request must contain the distinguished name of the key to be deleted.
///
/// /// Syntax : delete:<key to be deleted>
/// e.g.
/// @alice@delete:public:phone@alice - delete alice's public phone number
/// dAt:
/// Caller-asserted deletion time (ISO 8601 UTC), recorded as the DELETE
/// commit log entry's operation time and carried to the sharedWith
/// atServer's cached-key delete —
/// delete:dAt:2026-05-05T11:59:44.123456Z:@bob:phone@alice
/// nc (no-commit):
/// Performs the delete as usual (auto-notification included) but writes no
/// commit log entry AND removes the key's existing entry; the response is
/// data:-1. Works for a key that is already gone, which is how a client
/// removes stale commit log entries found via scan:cl —
/// delete:nc:@bob:phone@alice
class Delete extends Verb {
  @override
  String name() => 'delete';

  @override
  String syntax() => VerbSyntax.delete;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'syntax delete:@<atkey> \n e.g delete:phone@alice';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
