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

  /// Throws rather than returning an unmodified pattern. A failed insertion
  /// would leave `enroll:infons` rejected as a syntax error, which reads
  /// exactly like the verb not existing.
  ///
  /// This is lazy: `_syntaxWithInfons` is a `static final` whose only reader
  /// is the per-command verb lookup, so nothing evaluates it at start-up. A
  /// failure therefore surfaces on the first `enroll:` command the server
  /// receives — every one of them, loudly and identically — rather than at
  /// boot. Loud and late beats silent.
  static String _buildSyntax() {
    const insertionPoint = '(request|';
    final String upstream = VerbSyntax.enroll;
    if (upstream.contains('infons')) {
      // Checked FIRST, because the anchor test cannot see this case: at_commons
      // adds `infons` next to `listns`, leaving `(request|` untouched — so a
      // guard on the anchor alone would insert a duplicate and say nothing.
      throw StateError(
          'at_commons now defines the `infons` enroll operation itself, so '
          'this local override is a stale fork. Delete _buildSyntax and '
          '_syntaxWithInfons, return VerbSyntax.enroll from syntax(), raise '
          'the at_commons floor in the same commit, and delete '
          'at_secondary_server/test/enroll_verb_syntax_test.dart.');
    }
    if (!upstream.contains(insertionPoint)) {
      throw StateError(
          'at_server adds `infons` to the enroll syntax locally by inserting '
          'it into at_commons\'s operation alternation, which no longer '
          'contains "$insertionPoint". Check whether at_commons now defines '
          '`infons` itself: if it does, delete this override and return '
          'VerbSyntax.enroll. If it does not, find the new insertion point. '
          'Upstream pattern was: $upstream');
    }
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
