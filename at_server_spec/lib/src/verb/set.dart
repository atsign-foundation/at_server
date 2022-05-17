import 'package:at_commons/at_builders.dart';
import 'package:at_server_spec/at_server_spec.dart';

class Set extends Verb {
  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String name() {
    return 'set';
  }

  @override
  bool requiresAuth() {
    return true;
  }

  @override
  String syntax() {
    return VerbSyntax.set;
  }

  @override
  String usage() {
    return 'e.g. set:config1:value1';
  }
}
