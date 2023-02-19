import 'package:at_server_spec/src/verb/cram.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The update verb adds/updates the keys in the secondary server. The update verb is used to set public responses and specific responses for a particular authenticated users after using the pol verb.
/// The @sign should be authenticated using cram verb prior to use the update verb.
/// A malformed request closes the @sign client connection.
///
/// Syntax: update:[public/@sign]:key@[@sign] value
/// e.g.
/// update:public:phone@alice +1 123 456 000 - update public phone number of alice
/// update:@bob:phone@alice +1 123 456 001 - update phone number of alice shared with bob
/// update:@alice:phone@alice + 123 456 002 - update private phone number of alice
/// ttl - time to live
/// Defines the time after which value should expire
/// Accepts time duration in milliseconds
/// example: update:ttl:60000:@alice:otp@bob 9901 - update the otp of bob shared with alice, the value exists till the ttl time mentioned(60000ms -60sec)
/// ttb - time to born
/// Defines the time after which value should be displayed
/// Accepts time duration in milliseconds
/// example: update:ttb:60000:@alice:otp@bob 9901 - update the otp of bob shared with alice, the value appears after the ttb time mentioned(60000ms -60sec)
/// ttr:
///   Creates a cached key at the receiver side.
///   Accepts a time duration in milli seconds which is a positive integer value to refresh the cached key or -1 to cache for forever.
///   Example: update:ttr:-1:@alice:city@bob california.
class Update extends Verb {
  @override
  String name() => 'update';

  @override
  String syntax() => VerbSyntax.update;

  @override
  Verb dependsOn() {
    return Cram();
  }

  @override
  String usage() {
    return 'e.g. update:@alice:location@bob San Francisco';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
