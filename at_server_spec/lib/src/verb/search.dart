import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

class Search extends Verb {
  @override
  Verb dependsOn() {
    return null;
  }

  @override
  String name() => 'search';

  @override
  bool requiresAuth() {
    return false;
  }

  @override
  // TODO: Move syntax to VerbSyntax
  String syntax() => VerbSyntax.search;

  @override
  String usage() {
    return 'syntax search:<space/comma seperated strings> \n e.g search:alice newyork';
  }
}