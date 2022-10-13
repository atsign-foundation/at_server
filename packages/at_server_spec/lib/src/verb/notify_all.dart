import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The “notify:all” allows to notify multiple @sign's at the same time .
/// The @sign should be authenticated using the cram/pkam verb prior to use the notify verb.
/// A malformed request closes the @sign client connection.
///
/// Syntax: notify:<atsign's to notify>:<key to notify>@<sender AtSign>
/// Optionally following preferences can be set
/// 1) messageType: KEY, TEXT
///   This field indicates the type of notification. This is an optional field. Defaults to Key.
///   KEY: To notify a key
///     Example: notify:all:messageType:key:@colin:phone@kevin
///   TEXT: To notify a message.
///     Example: notify:all:messageType:text:@colin:hi
/// 2) operation: UPDATE, DELETE
/// This field indicates the operation. This is an optional field. Defaults to update
///  Type: update
/// Example: notify:update:key:@alice:phone@bob:+91-90192019201
///  Type:delete
/// Example: notify:delete:key:@alice:phone@bob
class NotifyAll extends Verb {
  @override
  String name() => 'notifyAll';

  @override
  String syntax() => VerbSyntax.notifyAll;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g notify:all:@alice,@bob:key1@colin';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
