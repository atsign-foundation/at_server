import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

///
/// stats verb used to get all the available metrics
/// Syntax: stats
/// example: Number of active inbound/outbound connections, last commit ID etc.
/// These are the available metrics
/// '1' - Number of active inbound connections
/// '2' - Number of active outbound connections
/// '3' - Last Commit Id
/// '4' - Total Secondary storage size
/// '5' - Most Visited AtSign
/// '6' - Most Visited AtKeys
/// '7' - Secondary Server Version,
/// '8' - Last log in date time,
/// '9' - Total Disk Size
/// '10' - Last login datetime with PKAM
/// '11' - Notification count
/// Syntax: stats - List all the available metrics
/// We can provide specific metrics id's as a comma separated list
/// e.g. stats:1,2,3
/// stats:10
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
