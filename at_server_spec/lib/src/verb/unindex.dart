import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

class UnIndex extends Verb {
  @override
  Verb dependsOn() {
    return null;
  }

  @override
  String name() => 'unindex';

  @override
  bool requiresAuth() {
    return true;
  }

  @override
  String syntax() => VerbSyntax.unindex;

  @override
  String usage() {
    return 'syntax: unindex\n';
  }
}