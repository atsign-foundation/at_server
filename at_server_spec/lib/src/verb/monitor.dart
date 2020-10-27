import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

class Monitor extends Verb {
  @override
  Verb dependsOn() {
    return null;
  }

  @override
  String name() => 'monitor';

  @override
  bool requiresAuth() {
    return true;
  }

  @override
  String syntax() => VerbSyntax.monitor;

  @override
  String usage() {
    // TODO: implement usage
    throw UnimplementedError();
  }
}
