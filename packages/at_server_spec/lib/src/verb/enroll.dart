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
  /// ⚠️ TEMPORARY LOCAL OVERRIDE. Delete this and return [VerbSyntax.enroll]
  /// once a published at_commons lists `infons` itself.
  ///
  /// at_commons owns the enroll operation alternation, and it does not yet
  /// know `infons` — so `enroll:infons:<namespace>` is rejected as invalid
  /// syntax before it reaches a handler. Every other verb in this package
  /// takes its syntax from at_commons unchanged, and this one should again.
  ///
  /// Built by INSERTING into at_commons's pattern rather than by copying it,
  /// so that any other upstream change to the enroll syntax still reaches this
  /// server. Only the one addition is local.
  static final String _syntaxWithInfons = _buildSyntax();

  /// Never throws, and that is deliberate: this runs per command, so an
  /// exception here takes out EVERY enroll operation — `enroll:request`
  /// included, which is unauthenticated onboarding — rather than just the one
  /// operation it is about.
  ///
  /// Two ways the insertion can fail to apply, both benign:
  ///
  /// * at_commons already lists `infons`. Inserting a second alternative would
  ///   be inert — a regex alternation matches the same strings either way —
  ///   but there is nothing to add, so the upstream pattern is returned whole.
  ///   `enroll_verb_syntax_test.dart` fails deliberately in this case, which is
  ///   the signal to delete this override; a running server keeps working.
  /// * the anchor has moved. `replaceFirst` returns the pattern unchanged,
  ///   `enroll:infons` is rejected as a syntax error, and every other enroll
  ///   operation still works. Caught by the syntax test rather than at
  ///   runtime, which is the right place for it: the alternative was throwing,
  ///   and that took the whole verb down to report that one operation was
  ///   missing.
  static String _buildSyntax() {
    const insertionPoint = '(request|';
    final String upstream = VerbSyntax.enroll;
    if (upstream.contains('infons')) {
      return upstream;
    }
    // `replaceFirst` is already a no-op on a missing anchor, so this needs no
    // branch of its own: a moved anchor returns the pattern unchanged and
    // `enroll_verb_syntax_test.dart`'s first test — which asserts
    // `enroll:infons:wavi` parses — goes red. That test is the detector,
    // deliberately, because this package has no logger dependency and adding
    // one to a published package for a single line is the wrong trade.
    return upstream.replaceFirst(insertionPoint, '${insertionPoint}infons|');
  }

  @override
  String name() => 'enroll';

  @override
  String syntax() => _syntaxWithInfons;

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
