import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The gate verb sets and reads an atSign's gate: its default, each
/// namespace's rule, and the atSigns admitted or denied in it.
class Gate extends Verb {
  @override
  String name() => 'gate';

  @override
  String syntax() => VerbSyntax.gate;

  @override
  String usage() => 'e.g. gate:rule:chat:closed:admit:@bob, gate:show:chat';

  @override
  bool requiresAuth() => true;

  @override
  Verb? dependsOn() => null;
}
