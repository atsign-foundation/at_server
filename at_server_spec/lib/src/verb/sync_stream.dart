import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The "ssync" (stream sync) verb sets up a two-way stream for syncing between client and server.
/// Initially the client calls ssync with 'from:' to fetch all the keys after a given commit sequence number
/// from the commit log on the server. Once the server has sent all of those, subsequent updates from the
/// server are streamed as they happen.
///
/// Optionally the client may pass a regex to fetch only keys that match the regex. This regex is applied
/// both to the initial response and to all subsequent updates.
///
/// Syntax: ssync:from:<from_commit_seq>:<regex>
/// e.g. ssync:from:10:.name.space
///
/// The server streams messages like this: srid:<srid>:commitEntry:<JSON-encoded commit entry>
///
/// In order to prevent the server from flooding the socket, the client sends 'ssync:ack:<srid>' as it
/// finishes handling each message from the server
///
class SyncStream extends Verb {
  @override
  String name() => 'ssync';

  @override
  String syntax() => VerbSyntax.syncStream;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return syntax();
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
