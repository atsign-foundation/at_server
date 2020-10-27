import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// To delete an entry, an @sign client transmits a well formed delete request to the @sign secondary server.
/// The @sign should be authenticated using the cram verb prior to use the delete verb.
/// A malformed request closes the @sign client connection.
/// A delete request must contain the distinguished name of the key to be deleted.
///
/// Syntax : delete:<key to be deleted>
class Delete extends Verb {
  @override
  String name() => 'delete';

  @override
  String syntax() => VerbSyntax.delete;

  @override
  Verb dependsOn() {
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
