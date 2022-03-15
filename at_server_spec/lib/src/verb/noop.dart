import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "noop" verb takes a single parameter, a duration in milliseconds.
///
/// NoOp simply does nothing for the requested number of milliseconds.
/// The requested number of milliseconds may not be greater than 5000.
/// Upon completion, the noop verb sends 'OK' as a response to the client.
///
/// This verb _does not_ require authentication.
///
/// **Syntax**: noop:<durationInMillis>
class NoOp extends Verb {
  @override
  String name() => 'noop';

  @override
  String syntax() => VerbSyntax.noop;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'noop:<durationInMillis>';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
