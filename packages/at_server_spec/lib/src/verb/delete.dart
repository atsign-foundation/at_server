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
