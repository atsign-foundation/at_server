import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The "info" verb returns a JSON object as follows:
/// ```json
/// {
///   "version" : "the version being run",
///   "uptimeAsWords" : "uptime as string: D days, H hours, M minutes, S seconds",
///   "features" : [
///     {
///       "name" : "ID of feature 1",
///       "status" : "One of Preview, Beta, GA",
///       "description" : "Description of feature"
///     },
///     {
///       "name" : "ID of feature 2",
///       "status" : "One of Preview, Beta, GA",
///       "description" : "Description of feature"
///     },
///     ...
///   ]
/// }
/// ```
/// `info:brief` will just return the version and uptime as milliseconds
/// ```json
/// {
///   "version" : "the version being run",
///   "uptimeAsMillis" : "uptime in milliseconds, as integer",
/// }
/// ```
///
/// This verb _does not_ require authentication.
///
/// **Syntax**: info
class Info extends Verb {
  @override
  String name() => 'info';

  @override
  String syntax() => VerbSyntax.info;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'info';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
