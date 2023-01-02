import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The "sync" verb is used to fetch all the keys after a given commit sequence number from the commit log on the server
/// Optionally pass a regex to fetch only keys that match the regex
/// Syntax: sync:from:<from_commit_seq>:limit:<10>:<regex>
/// e.g. sync:from:10:limit:10:.wavi
/// sync:10:.wavi
class SyncFrom extends Verb {
  @override
  String name() => 'sync:from';

  @override
  String syntax() => VerbSyntax.syncFrom;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'syntax sync:from:1:limit:10:.wavi';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
