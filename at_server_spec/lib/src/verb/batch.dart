import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// #TODO add docs
///
class Batch extends Verb {
  @override
  String name() => 'batch';

  @override
  String syntax() => VerbSyntax.batch;

  @override
  Verb dependsOn() {
    return Pkam();
  }

  @override
  String usage() {
    return 'e.g batch:[{"id":1, "commmand":"update:location@alice newyork"},{"id":2, "commmand":"delete:location@alice"}]';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
