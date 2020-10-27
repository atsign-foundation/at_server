import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';

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
