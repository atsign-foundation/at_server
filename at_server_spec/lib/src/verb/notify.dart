import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The “notify” verb allows to notify the another @sign.
/// The @sign should be authenticated using the cram/pkam verb prior to use the notify verb.
/// A malformed request does not close the @sign client connection.
///
/// Syntax: notify:notifier:<notifier-id>:<atsign to notify>:<key to notify>@<sender AtSign>
/// Optionally, following preferences can be set on the notification:
/// messageType: KEY, TEXT
///   This field indicates the type of notification. This is an optional field. Defaults to Key.
///   KEY: To notify a key
///     Example: notify:messageType:key:@colin:phone@kevin
///   TEXT: To notify a message.
///     Example: notify:messageType:text:@colin:hi
/// priority: LOW, MEDIUM, HIGH
///   This fields indicates the priority of the notification. Defaults to low priority.
///   Example: notify:priority:low:@murali:key1@sitaram
/// strategy: ALL, LATEST
///   Strategy 'ALL' ensures to deliver all the notifications.
///     Example: notify:strategy:all:@alice:location@bob
///   Strategy 'LATEST' notifies the latest N notifications. When strategy is set to latest, following preferences are to be set:
///     Notifier: This is a mandatory field. The notifier groups the notifications with same notifier and deliver the latest N notifications.
///     LatestN: This is optional field. The latest N notifications to deliver. Defaults to 1.
///     Example: notify:strategy:latest:latestN:5:notifier:wavi:@alice:location@bob
/// ttr:
///   Creates a cached key at the receiver side.
///   Accepts a time duration in seconds which is a positive integer value to refresh the cached key or -1 to cache for forever.
///   Example: notify:ttr:-1:@alice:city@bob:california.
/// ttln:
///   Defines the time after the notification should expire.
///   Accepts a time duration in milliseconds
/// Example : notify:ttln:60:@alice:pin@bob:99001
///
class Notify extends Verb {
  @override
  String name() => 'notify';

  @override
  String syntax() => VerbSyntax.notify;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g notify:@colin:key@kevin';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
