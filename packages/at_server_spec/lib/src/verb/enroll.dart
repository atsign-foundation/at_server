import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// Enroll verb enables a new app or client to request new enrollment to a secondary server
/// Secondary server will notify the new enrollment request to already enrolled apps which have access to __manage namespace.
/// The enrolled app which receives the notification may approve or reject the enrollment request.
/// Syntax
/// enroll:request:appName:<appName>:deviceName:<deviceName>:namespaces:<namespaces>:otp:<otp>:apkamPublicKey:<apkamPublicKey>
/// appName - Name of the app or client requesting enrollment
/// deviceName- Name of the device or client
/// namespaces - List of namespaces the requesting app or client needs access e.g [wavi,r;buzz,rw]
/// otp - timebased OTP which has to fetched from an already enrolled app
/// apkamPublicKey - new pkam public key from the requesting app/client
class Enroll extends Verb {
  @override
  String name() => 'enroll';

  @override
  String syntax() => VerbSyntax.enroll;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'enroll:request:{"appName":"wavi","deviceName":"iPhone","namespaces":{"wavi":"rw"},"otp":"<otp>":"apkamPublicKey":"<public_key>"}';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
