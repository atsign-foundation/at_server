import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "syncStream" verb is used to fetch all the changes after a given commit sequence number from the commit log on the server
///
/// Syntax: sync:stream:<from_commit_seq>
class SyncStream extends Verb {
  @override
  String name() => 'sync:stream';

  @override
  String syntax() => VerbSyntax.syncStream;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'syntax sync:stream:@<from_commit_seq>\n e.g sync:stream:10';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
