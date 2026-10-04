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
///       "status" : "One of Preview, Beta, GA, Deprecated, Retired",
///       "description" : "Description of feature"
///     },
///     {
///       "name" : "ID of feature 2",
///       "status" : "One of Preview, Beta, GA, Deprecated, Retired",
///       "description" : "Description of feature"
///     },
///     ...
///   ]
/// }
/// ```
/// `info:brief` will just return the version, the features and uptime as
/// milliseconds
/// ```json
/// {
///   "version" : "the version being run",
///   "features" : [ ... ],
///   "uptimeAsMillis" : "uptime in milliseconds, as integer",
/// }
/// ```
///
/// Every form of `info` lists the features. A client checks a feature by its
/// `name` and `status`: a Deprecated feature still works but will be retired,
/// and a Retired one is refused. The names in use are:
/// - `notify.multi`: the server takes the `notify:multi` verb.
/// - `notify.eph`: the server takes `eph`, an ephemeral notification.
/// - `notify.eAtn`: the server takes `eAtn`, an expiry the client sets.
/// - `notify.all`: the `notify:all` verb, Deprecated in favour of
///   `notify:multi`.
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
