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
///       "status" : "Status of feature 1",
///       "description" : "Description of feature"
///     },
///     {
///       "name" : "ID of feature 2",
///       "status" : "Status of feature 2",
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
/// Every form of `info` lists the features. Their names are [InfoFeature],
/// their statuses [InfoFeatureStatus], and [InfoFeatures] reads them; each
/// atServer decides the status it gives each feature.
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
