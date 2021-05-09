import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

class StreamVerb extends Verb {
  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String name() => 'stream';

  @override
  bool requiresAuth() {
    return false;
  }

  @override
  String syntax() => VerbSyntax.stream;

  @override
  String usage() {
//    #TODO add usage
    return '';
  }
}
