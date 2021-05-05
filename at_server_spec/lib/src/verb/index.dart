import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

class Index extends Verb {
  @override
  Verb dependsOn() {
    return null;
  }

  @override
  String name() => 'index';

  @override
  bool requiresAuth() {
    return true;
  }

  @override
  // TODO: Move syntax to VerbSyntax
  String syntax() => r'^index:(?<json>.+$)';

  @override
  String usage() {
    return 'syntax index:<json> \n e.g index:{"name": "alice", "age": "21 years"}';
  }
}