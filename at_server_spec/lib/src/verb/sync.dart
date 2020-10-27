import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "sync" verb is used to fetch all the changes after a given commit sequence number from the commit log on the server
///
/// Syntax: sync:<from_commit_seq>
class Sync extends Verb {
  @override
  String name() => 'sync';

  @override
  String syntax() => VerbSyntax.sync;

  @override
  Verb dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'syntax sync:@<from_commit_seq> \n e.g sync:10';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
