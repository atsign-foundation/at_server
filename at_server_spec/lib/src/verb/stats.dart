import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// Syntax: stats
/// stats verb used to get all the available metrics
/// example: Number of active inbound/outbound connections, last commit ID etc.
class Stats extends Verb {
  @override
  String name() => 'stats';

  @override
  String syntax() => VerbSyntax.stats;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'stats:1,2,3';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
