import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// Monitor verb is used to stream incoming connections from the secondary server
/// to the client. Optionally pass a regex to stream only notifications that match the regex.
/// e.g. monitor or monitor .wavi
class Monitor extends Verb {
  @override
  Verb? dependsOn() {
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
    return 'e.g. monitor or monitor .wavi';
  }
}
