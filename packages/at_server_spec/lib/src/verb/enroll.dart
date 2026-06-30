import 'package:at_server_spec/src/verb/verb.dart';

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
///
/// Extended operations (WP-SS):
/// enroll:listfornamespace:<namespace>
///   Returns all approved enrollments with namespace access plus their key packages.
/// enroll:metadata:<enrollmentId>:<jsonMetadata>
///   Stores opaque metadata (key packages) on the caller's own enrollment record.
class Enroll extends Verb {
  /// Extended regex that adds `listfornamespace` and `metadata` to the allowed
  /// operations, and captures an optional `namespace` segment after the
  /// operation (used by both new verbs: namespace name for listfornamespace,
  /// enrollmentId for metadata).
  static const String extendedSyntax =
      r'^enroll:(?<operation>(?:(request|approve|deny|revoke|list|listfornamespace|fetch|unrevoke|delete|metadata)))'
      r'(:(?<force>force))?(:(?<namespace>[^:{\n]+))?(?::)?((?<enrollParams>.+)|(<=list:)<enrollParams>.?)?$';

  @override
  String name() => 'enroll';

  @override
  String syntax() => extendedSyntax;

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
