import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';


/// The update meta verb updates the metadata of the keys in the secondary server. The update meta verb is used to set/update metadata of a key.
/// The @sign should be authenticated using cram verb prior to use the update meta verb.
/// A malformed request closes the @sign client connection.
///
/// Syntax: update:meta:
/// e.g.
/// update:meta:public:phone@alice +1 123 456 000 - update public phone number of alice
/// update:@bob:phone@alice +1 123 456 001 - update phone number of alice shared with bob
/// update:@alice:phone@alice + 123 456 002 - update private phone number of alice
class UpdateMeta extends Verb {
  @override
  Verb dependsOn() => Cram();

  @override
  String name() => 'update:meta';

  @override
  bool requiresAuth() => true;

  @override
  String syntax() => VerbSyntax.update_meta;

  @override
  String usage() => 'update:meta:ttl:20000:ttb:20000:ttr:20000';
}
